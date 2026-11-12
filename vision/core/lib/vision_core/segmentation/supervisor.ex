defmodule VisionCore.Segmentation.Supervisor do
  @moduledoc """
  Supervises a segmentation unit, one segmentation pipeline: an
  inference backend, the `VisionCore.Segmentation.Pipeline` that sorts
  the stereo points seen by its camera into road and off-road, and
  `VisionCore.Segmentation.Live`, which hands its label images to the
  dashboard.

  `:name` (required) names the pipeline (`VisionCore.Segmentation`): the
  unit, its backend, pipeline and `Live` register under it
  (`VisionCore.Detection.server/2`). A unit without a valid name is left
  down.

  Which backend is `:backend`, defaulting to
  `VisionCore.Segmentation.Backend.Qnn`, on a Qualcomm Hexagon NPU;
  `VisionCore.Segmentation.Backend.Stub` is for plumbing only.

  As `VisionCore.Detection.Supervisor`, and for the same reasons, it
  exists to contain failure: its own restart budget keeps a crash loop
  from reaching the vision core's supervisor, and `:rest_for_one`
  restarts the pipeline with its backend, so a pipeline waiting for a
  reply the restarted backend will never send starts over.

  The backend's options go to the backend, the pipeline's to the
  pipeline, and `:max_hz`, `:labels` and `:road_classes` to `Live`; see
  their docs. A unit that fails to start, such as one given an option it
  does not take, is left down, with the reason logged, and the rest of
  the vision core runs on; the log names the ROS 2 exporter's
  `segmentation:` for its `:topic_prefix`.
  """
  use Supervisor
  require Logger

  alias VisionCore.{Detection, Segmentation}
  alias VisionCore.Segmentation.{Live, Pipeline}

  @default_backend Segmentation.Backend.Qnn
  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60

  @doc """
  Starts the segmentation unit; see the module doc for `opts`. `:ignore`
  when it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    registration =
      if Detection.name?(name), do: [name: Detection.server(__MODULE__, name)], else: []

    server = Keyword.get(registration, :name, __MODULE__)

    case Supervisor.start_link(__MODULE__, opts, registration) do
      {:error, reason} ->
        Logger.error("#{inspect(server)} failed to start, #{name} down: #{failure_text(reason)}")
        :ignore

      started ->
        started
    end
  end

  defp failure_text({:shutdown, {:failed_to_start_child, _child, reason}}),
    do: failure_text(reason)

  defp failure_text({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp failure_text(reason) when is_binary(reason), do: reason
  defp failure_text(reason), do: inspect(reason)

  @impl Supervisor
  def init(opts) do
    check_options!(opts)
    name = Segmentation.name!(opts)
    {backend, backend_opts} = split_backend_options(opts)
    backend_server = Detection.server(backend, name)

    children = [
      {backend, backend_opts ++ [name: backend_server, pipeline: name]},
      {Pipeline,
       Keyword.take(opts, pipeline_keys()) ++
         [backend: backend, backend_server: backend_server, name: name]},
      {Live, Keyword.take(opts, [:max_hz, :labels, :road_classes]) ++ [name: name]}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc """
  The outputs of the segmentation units in `config`, in config order,
  with their `VisionCore.Outputs` keys: `{:segmentation, name}`, as
  `VisionCore.Exporter` names each pipeline's. `[]` when no component of
  `config` starts a unit.
  """
  @spec outputs(VisionCore.Config.t()) :: [{{:segmentation, atom()}, VisionCore.Outputs.key()}]
  def outputs(config) do
    for opts <- units_options(config) do
      name = Keyword.fetch!(opts, :name)
      {Segmentation.output(name), {:segmentation, Detection.server(Pipeline, name)}}
    end
  end

  @doc """
  The source of each segmentation unit in `config`, in config order, by
  its output (`outputs/1`): `{:camera, name}`, or whatever its `:source`
  holds, `nil` without one, for a unit left down.
  """
  @spec sources(VisionCore.Config.t()) :: [{{:segmentation, atom()}, term()}]
  def sources(config) do
    for opts <- units_options(config),
        do: {Segmentation.output(Keyword.fetch!(opts, :name)), Keyword.get(opts, :source)}
  end

  @doc """
  Each segmentation unit in `config` whose source is a camera of its
  own, in config order, as its pipeline name and the camera's name; a
  unit with another source never runs, so it is left out.
  """
  @spec cameras(VisionCore.Config.t()) :: [{atom(), atom()}]
  def cameras(config) do
    for {{:segmentation, name}, {:camera, camera}} <- sources(config), do: {name, camera}
  end

  @doc """
  Each segmentation unit in `config`, in config order, as its pipeline
  name, its backend module and the name the backend is registered under.
  """
  @spec pipelines(VisionCore.Config.t()) :: [{atom(), module(), server :: module()}]
  def pipelines(config) do
    for opts <- units_options(config) do
      {backend, _backend_opts} = split_backend_options(opts)
      name = Keyword.fetch!(opts, :name)
      {name, backend, Detection.server(backend, name)}
    end
  end

  # The options of the units `config`'s components start, as `VisionCore.Components` resolves them.
  defp units_options(%VisionCore.Config{components: components}) do
    for component <- components,
        {name, opts} = if(is_atom(component), do: {component, []}, else: component),
        %{start: {__MODULE__, _function, [unit_opts]}} <- VisionCore.Components.start(name, opts),
        do: unit_opts
  end

  defp check_options!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- options() do
      [] -> :ok
      refused -> raise ArgumentError, Enum.map_join(refused, "; ", &refused_option/1)
    end
  end

  defp refused_option(:topic_prefix),
    do:
      "its :topic_prefix is the ROS 2 exporter's segmentation: option " <>
        "(VisionCore.Ros2.Exporter)"

  defp refused_option(option), do: "it has no option #{inspect(option)}"

  defp options, do: [:name, :backend, :max_hz] ++ pipeline_keys() ++ backend_keys()

  defp split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp pipeline_keys do
    [:source, :band_top, :labels, :road_classes, :segment_every_n] ++
      [:reprojection_stride, :pair_wait_ms, :config]
  end

  # The options of `Backend.Qnn` and `Backend.Stub`.
  defp backend_keys do
    [:dlc_path, :qairt_dir, :dsp_library_path, :cache_dir, :executable] ++
      [:infer_timeout_ms, :reopen_delays_ms, :label_image]
  end
end
