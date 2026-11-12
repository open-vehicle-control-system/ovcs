defmodule VisionCore.Detection.Supervisor do
  @moduledoc """
  Supervises a detection unit, one detection pipeline: an inference
  backend, the `VisionCore.Detection.Pipeline` that places its boxes in
  3D with the stereo depth, on the stereo pair or a camera of its own
  (its `:source`), and `VisionCore.Detection.Live`, which hands
  them to the dashboard. `VisionCore.Ros2.Exporter` publishes them on
  ROS 2, outside the unit.

  `:name` (`:detection`) names the pipeline (`VisionCore.Detection`): the
  unit, its backend, pipeline and `Live` register under it
  (`VisionCore.Detection.server/2`), so a unit runs several pipelines,
  each under its own supervisor, with its own backend and model. A name
  that is not a valid pipeline name leaves the unit down.

  Which backend is `:backend`, defaulting to the Hailo-8 accelerator,
  `VisionCore.Detection.Backend.Hailo`; `VisionCore.Detection.Backend.Qnn`
  runs on a Qualcomm Hexagon NPU. See `VisionCore.Detection.Backend` for
  `Stub`, for plumbing only. A Hailo unit first claims the accelerator
  (`VisionCore.Detection.Backend.Hailo.Device`), which one pipeline at a
  time runs on: a second Hailo unit is left down, saying so.

  Exists to contain failure rather than to organise code. The vision
  core's own supervisor is `:rest_for_one` with the default restart
  intensity, and the detection pipeline handles a cast at the stereo
  frame rate — so a bug that raises on every frame would exhaust that
  budget almost at once and take the *whole* vision core down, cameras
  and depth included. Under this supervisor the same bug restarts the
  detector within its own budget and stops there, leaving the stereo
  unit untouched. Detections go away; depth does not.

  `:rest_for_one` because a backend restart strands the pipeline: it
  holds the pair whose image is at the accelerator and waits for a
  reply keyed on its sequence number. That reply is never coming, and
  nothing times it out, so it would hold a stale depth map and discard
  every later answer as stale. Restarting it alongside clears that. Not
  the reverse: a backend is told where to reply on every call and holds
  nothing across one.

  The backend's options go to the backend, the pipeline's to the
  pipeline and `:max_hz` to `Live`; see their docs. How the detections
  are published is the exporters' business: the ROS 2 exporter's are its
  `detections:` options (`VisionCore.Ros2.Exporter`), and their frame
  is the one their pair carries, the stereo unit's left `:frame_id`, or
  on a camera source the camera's.

  A unit that fails to start, such as one whose backend cannot, or one
  given an option it does not take, is left down, with the reason
  logged, and the rest of the vision core runs on. The refusal of an
  option another component or exporter takes names where it belongs.
  """
  use Supervisor
  require Logger

  alias VisionCore.Detection
  alias VisionCore.Detection.{Live, Pipeline}
  alias VisionCore.Detection.Backend.Hailo

  @default_backend Hailo
  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60
  @exporter_options [:topic_prefix, :marker_lifetime_ms, :label_font_size]

  @doc """
  Starts the detection unit; see the module doc for `opts`. `:ignore`
  when it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    name = Detection.pipeline_name(opts)
    server = Detection.server(__MODULE__, name)

    case Supervisor.start_link(__MODULE__, opts, name: server) do
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
    name = opts |> Detection.pipeline_name() |> Detection.name!()
    {backend, backend_opts} = split_backend_options(opts)
    backend_server = Detection.server(backend, name)

    children =
      device_claim(backend, name) ++
        [
          {backend, backend_opts ++ [name: backend_server, pipeline: name]},
          {Pipeline,
           Keyword.take(opts, pipeline_keys()) ++
             [backend: backend, backend_server: backend_server, name: name]},
          {Live, Keyword.take(opts, [:max_hz]) ++ [name: name]}
        ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  defp device_claim(Hailo, name), do: [{Hailo.Device, pipeline: name}]
  defp device_claim(_backend, _name), do: []

  @doc """
  The outputs of the detection units in `config`, in config order, with
  their `VisionCore.Outputs` keys: each pipeline's detections, as
  `VisionCore.Exporter` names them, `:detections` for the default
  pipeline and `{:detections, name}` for a named one. `[]` when no
  component of `config` starts a unit, as `VisionCore.Components`
  resolves them.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    for opts <- units_options(config) do
      name = Detection.pipeline_name(opts)
      {Detection.output(name), {:detections, Detection.server(Pipeline, name)}}
    end
  end

  @doc """
  The source of each detection unit in `config`, in config order, with
  its output (`outputs/1`): `:stereo`, the stereo pair's, `{:camera,
  name}`, the camera of its own `name`, or `{:camera, name, output}`, one
  of its outputs (`VisionCore.Detection.Pipeline`). A unit with another
  source never runs, so it is left out.
  """
  @spec sources(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), :stereo | {:camera, atom()} | {:camera, atom(), atom()}}
        ]
  def sources(config) do
    for opts <- units_options(config),
        source = Keyword.get(opts, :source, :stereo),
        source?(source),
        do: {Detection.output(Detection.pipeline_name(opts)), source}
  end

  defp source?(:stereo), do: true
  defp source?({:camera, camera}), do: is_atom(camera)
  defp source?({:camera, camera, output}), do: is_atom(camera) and is_atom(output)
  defp source?(_other), do: false

  @doc """
  The backend of each detection unit in `config`, in config order: its
  module and the name it is registered under. `[]` when no component of
  `config` starts a unit.
  """
  @spec backends(VisionCore.Config.t()) :: [{module(), server :: module()}]
  def backends(config) do
    for {_name, backend, server} <- pipelines(config), do: {backend, server}
  end

  @doc """
  Each detection unit in `config`, in config order, as its pipeline name,
  its backend module and the name the backend is registered under.
  """
  @spec pipelines(VisionCore.Config.t()) :: [{atom(), module(), server :: module()}]
  def pipelines(config) do
    for opts <- units_options(config) do
      {backend, _backend_opts} = split_backend_options(opts)
      name = Detection.pipeline_name(opts)
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

  defp refused_option(:frame_id),
    do: "its :frame_id is the stereo unit's: each side's :frame_id, which the pairs carry"

  defp refused_option(option) when option in @exporter_options,
    do:
      "its #{inspect(option)} is the ROS 2 exporter's detections: option " <>
        "(VisionCore.Ros2.Exporter)"

  defp refused_option(option), do: "it has no option #{inspect(option)}"

  defp options, do: [:name, :backend, :max_hz] ++ pipeline_keys() ++ backend_keys()

  @doc false
  def split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp pipeline_keys do
    [:source, :detect_every_n, :labels, :min_score, :max_detections, :depth_sample_fraction] ++
      [:outline_segments, :reprojection_stride, :pair_wait_ms]
  end

  # The options of `Backend.Hailo`, `Backend.Qnn` and `Backend.Stub`.
  defp backend_keys do
    [:hef_path, :score_threshold, :executable, :working_directory, :library_path] ++
      [:dlc_path, :qairt_dir, :dsp_library_path, :cache_dir] ++
      [:infer_timeout_ms, :reopen_delays_ms, :performance, :boxes]
  end
end
