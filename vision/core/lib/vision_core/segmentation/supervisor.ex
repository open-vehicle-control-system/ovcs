defmodule VisionCore.Segmentation.Supervisor do
  @moduledoc """
  Supervises a segmentation unit, one segmentation pipeline: an
  inference backend, the `VisionCore.Segmentation.Pipeline` that sorts
  the stereo points seen by its camera into road and off-road, and
  `VisionCore.Segmentation.Live`, which hands its label images to the
  dashboard.

  `:name` (required) names the pipeline (`VisionCore.Segmentation`): the
  unit, its backend, pipeline and `Live` register under it
  (`VisionCore.Detection.server/2`). Started from a configuration, a
  segmenter without a valid name fails the vision core's start, as a
  detector with an invalid one does (`VisionCore.Application`); started
  directly, a unit without one is left down.

  Which backend is `:backend`, defaulting to
  `VisionCore.Segmentation.Backend.Qnn`, on a Qualcomm Hexagon NPU;
  `VisionCore.Segmentation.Backend.Stub` is for plumbing only.

  As `VisionCore.Detection.Supervisor`, and for the same reasons, it
  exists to contain failure: its own restart budget keeps a crash loop
  from reaching the vision core's supervisor, and `:rest_for_one`
  restarts the pipeline with its backend, so a pipeline waiting for a
  reply the restarted backend will never send starts over.

  The backend's options (`c:VisionCore.Segmentation.Backend.options/0`)
  go to the backend, with `:classes`, the number
  of `:labels`; the pipeline's to the pipeline, and `:max_hz` to `Live`;
  see their docs. A unit that fails to
  start, such as one given an option it does not take, is left down,
  with the reason logged, and the rest of the vision core runs on; the
  log names the ROS 2 exporter's `segmentation:` for its
  `:topic_prefix`.
  """
  use Supervisor

  alias VisionCore.{Detection, Segmentation, Unit}
  alias VisionCore.Segmentation.{Live, Pipeline}

  @default_backend Segmentation.Backend.Qnn
  @topic_prefix_hint "its :topic_prefix is the ROS 2 exporter's segmentation: option " <>
                       "(VisionCore.Ros2.Exporter)"
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

    Unit.start_contained(__MODULE__, opts, registration, "#{name}")
  end

  @impl Supervisor
  def init(opts) do
    {backend, backend_opts} = split_backend_options(opts)
    Unit.refuse_unknown!(opts, options(backend), %{topic_prefix: @topic_prefix_hint})
    name = Segmentation.name!(opts)
    backend_server = Detection.server(backend, name)
    classes = length(Keyword.get(opts, :labels, Segmentation.labels()))

    children = [
      {backend, backend_opts ++ [name: backend_server, pipeline: name, classes: classes]},
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
  its output (`outputs/1`): `{:camera, name}`, `{:camera, name, output}`,
  or whatever its `:source` holds, `nil` without one, for a unit left
  down.
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
    for {{:segmentation, name}, source} <- sources(config),
        camera = camera_name(source),
        do: {name, camera}
  end

  @doc """
  The names of the classes of the segmentation unit `name` in `config`,
  indexed by class id, and those of them that are road: its `:labels`
  and `:road_classes`. `nil` when `config` has no such unit.
  """
  @spec classes(VisionCore.Config.t(), atom()) ::
          %{labels: [String.t()], road_classes: [String.t()]} | nil
  def classes(config, name) do
    with opts when is_list(opts) <-
           Enum.find(units_options(config), &(Keyword.get(&1, :name) == name)) do
      %{
        labels: Keyword.get(opts, :labels, Segmentation.labels()),
        road_classes: Keyword.get(opts, :road_classes, Segmentation.road_classes())
      }
    end
  end

  defp camera_name({:camera, camera}), do: camera
  defp camera_name({:camera, camera, _output}), do: camera
  defp camera_name(_other), do: nil

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

  defp units_options(config), do: Unit.options_of(config, __MODULE__)

  defp options(backend), do: [:name, :backend, :max_hz] ++ pipeline_keys() ++ backend.options()

  defp split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend.options())}
  end

  defp pipeline_keys do
    [:source, :band_top, :labels, :road_classes, :segment_every_n] ++
      [:reprojection_stride, :pair_wait_ms, :config]
  end
end
