defmodule VisionCore.Application do
  @moduledoc """
  Starts the vision pipeline the vehicle's `VisionCore.Composer` declares.

  The composer is the `:vision_core, :vehicle` app env, set by the vision
  firmware's `config/runtime.exs`. With none set nothing starts.

  The pipeline is one `:rest_for_one` supervisor, `VisionCore.Supervisor`.
  `VisionCore.Parameters.Storage` and the `VisionCore.Parameters` registry
  come first, so saved values are loaded before any component declares its
  parameters and a restart of anything after them keeps the unsaved changes.
  `VisionCore.Outputs` follows them, before every process that publishes or
  subscribes through it.

  The ROS 2 link comes next, when the configuration has a `ros2:` section:
  `Ros2Zenoh.Client`, `VisionCore.Ros2.Parameters`,
  `VisionCore.Ros2.Topics`, which counts what is published on ROS 2, and
  with `simulator_clock:` `VisionCore.Ros2.Clock`. It starts before the
  components: the clock holds every stamp back until the simulator's first
  `/clock`, and a `VisionCore.Ros2.Camera` subscribes through the client
  from its `init/1`, so it must restart with the client to get its
  subscription back.

  The Port servers, `VisionCore.Jpeg` and `VisionCore.Stereo.Matcher`,
  start before the components and open their Ports on the first request,
  so a unit that computes no stereo stage natively never starts
  `stereo_match`; the Matcher runs the binary and thread count of
  `config :vision_core, :stereo_match_path` and `:stereo_match_threads`.

  A configuration with two detectors of one name fails the start, naming
  them, and so does one with two such segmenters
  (`VisionCore.Segmentation`), or a detector and a segmenter of one name. So does one with two cameras of one name
  (`VisionCore.Camera.Unit`), or a camera named as a detection or a
  segmentation pipeline, both publishing under `<prefix>/<name>/`. So
  does a detector or a segmenter whose `:name` is not a valid pipeline
  name, or a segmenter without one (`VisionCore.Pipelines.name!/2`).

  After the components come `VisionCore.Exporters`, which runs the
  configuration's exporters, then `VisionCore.Status`, which reports
  their statuses, and `VisionCore.Preview`: a restart of the dashboard's
  sources does not restart the exporters.

  `VisionCore.Jpeg` runs twice: the pipeline decodes JPEG camera frames
  on `VisionCore.Jpeg`, one Port, while the exporters and
  `VisionCore.Preview` encode on `VisionCore.Jpeg.Export`, a pool of
  Ports sized by the configuration's `jpeg:` options, apart from those
  decodes; `jpeg:` options other than a positive number of `:ports`
  fail the start. The
  second starts after the components, before the exporters, so that its
  restart reaches only what starts after it, its users among them, not
  the cameras and pipelines.
  """
  use Application

  alias VisionCore.{Detection, Segmentation}

  # Not the app env: `stop/1` runs while the application controller is
  # stopping the app, so a call to it from there times out.
  @active_config {__MODULE__, :active_config}
  @export_jpeg_codec VisionCore.Jpeg.Export

  @impl Application
  def start(_type, _args) do
    children =
      case Application.get_env(:vision_core, :vehicle) do
        nil ->
          []

        composer ->
          config = composer.config(VisionCore.arm())
          :persistent_term.put(@active_config, config)
          cluster_child() ++ [pipeline_child(config)]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: VisionCore.AppSupervisor)
  end

  @impl Application
  def stop(_state), do: :persistent_term.erase(@active_config)

  @doc "The `VisionCore.Config` the running pipeline started with, or `nil`."
  @spec active_config() :: VisionCore.Config.t() | nil
  def active_config, do: :persistent_term.get(@active_config, nil)

  defp pipeline_child(%VisionCore.Config{} = config) do
    core_children =
      [VisionCore.Parameters.Storage, VisionCore.Parameters, VisionCore.Outputs] ++
        [VisionCore.Processes] ++
        ros2_children(config.ros2) ++
        [
          {VisionCore.Jpeg, ports: 1},
          {VisionCore.Stereo.Matcher,
           path: Application.get_env(:vision_core, :stereo_match_path),
           threads: Application.get_env(:vision_core, :stereo_match_threads)}
        ]

    component_children = Enum.flat_map(config.components, &resolve_component/1)
    check_unit_names!(component_children, Detection.Supervisor, "detectors")
    check_unit_names!(component_children, Segmentation.Supervisor, "segmenters")
    check_pipeline_names!(component_children)
    check_camera_names!(component_children)
    check_jpeg!(config.jpeg)

    consumer_children = [
      {VisionCore.Jpeg, [name: @export_jpeg_codec] ++ config.jpeg},
      {VisionCore.Exporters, config: config, jpeg_codec: @export_jpeg_codec},
      {VisionCore.Status, config: config},
      {VisionCore.Preview, [config: config, jpeg_codec: @export_jpeg_codec] ++ config.preview}
    ]

    %{
      id: VisionCore.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           core_children ++ component_children ++ consumer_children,
           [strategy: :rest_for_one, name: VisionCore.Supervisor]
         ]}
    }
  end

  defp ros2_children(nil), do: []

  defp ros2_children(ros2) do
    check_ros2!(ros2)

    [
      {Ros2Zenoh.Client, zenoh_client_options(ros2)},
      VisionCore.Ros2.Parameters,
      VisionCore.Ros2.Topics
    ] ++ clock_children(Keyword.get(ros2, :simulator_clock))
  end

  defp check_ros2!(ros2) do
    cond do
      not (is_list(ros2) and Keyword.keyword?(ros2)) ->
        raise ArgumentError,
              "ros2: is a keyword list of the ROS 2 link's options, got #{inspect(ros2)}"

      not is_binary(ros2[:zenoh_endpoint_ip]) ->
        raise ArgumentError,
              "ros2: needs :zenoh_endpoint_ip, the Zenoh router's address as text, got " <>
                inspect(ros2[:zenoh_endpoint_ip])

      true ->
        :ok
    end
  end

  defp check_jpeg!(jpeg) do
    valid? =
      is_list(jpeg) and
        Enum.all?(jpeg, &match?({:ports, ports} when is_integer(ports) and ports > 0, &1))

    unless valid?,
      do: raise(ArgumentError, "jpeg: takes :ports, a positive integer, got #{inspect(jpeg)}")
  end

  # A key left out takes the client's default.
  defp zenoh_client_options(ros2) do
    [
      endpoint_ip: Keyword.fetch!(ros2, :zenoh_endpoint_ip),
      node_name: VisionCore.Ros2.Node.node_name(ros2)
    ] ++ if(domain_id = ros2[:domain_id], do: [domain_id: domain_id], else: [])
  end

  defp clock_children(clock) when clock in [nil, false], do: []
  defp clock_children(true), do: [{VisionCore.Ros2.Clock, []}]
  defp clock_children(options), do: [{VisionCore.Ros2.Clock, options}]

  # Two units of one name; the supervisor would refuse them less clearly.
  defp check_unit_names!(children, supervisor, units) do
    names = pipeline_names(children, supervisor)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [name | _others] ->
        raise ArgumentError, "two #{units} are named #{inspect(name)}: give each its own :name"
    end
  end

  # Detection and segmentation pipelines share their parameter groups', topics' and statuses' names.
  defp check_pipeline_names!(children) do
    detection = pipeline_names(children, Detection.Supervisor)

    case Enum.find(pipeline_names(children, Segmentation.Supervisor), &(&1 in detection)) do
      nil ->
        :ok

      name ->
        raise ArgumentError,
              "the detection pipeline and the segmentation pipeline #{inspect(name)} share " <>
                "their name: give them names apart"
    end
  end

  defp check_camera_names!(children) do
    cameras = for %{id: {:camera, name}} <- children, do: name

    pipelines =
      Enum.map(pipeline_names(children, Detection.Supervisor), &{"detection", &1}) ++
        Enum.map(pipeline_names(children, Segmentation.Supervisor), &{"segmentation", &1})

    case {cameras -- Enum.uniq(cameras),
          Enum.find(pipelines, fn {_kind, name} -> name in cameras end)} do
      {[name | _others], _shared} ->
        raise ArgumentError, "two cameras are named #{inspect(name)}: give each its own :name"

      {[], nil} ->
        :ok

      {[], {kind, name}} ->
        raise ArgumentError,
              "the camera and the #{kind} pipeline #{inspect(name)} share their name, " <>
                "under which both publish: give them names apart"
    end
  end

  # The pipeline names of the units `supervisor` starts among `children`.
  defp pipeline_names(children, Detection.Supervisor = supervisor),
    do:
      for(
        %{start: {^supervisor, _function, [opts]}} <- children,
        do: Detection.pipeline_name(opts)
      )

  defp pipeline_names(children, Segmentation.Supervisor = supervisor),
    do:
      for(%{start: {^supervisor, _function, [opts]}} <- children, do: Keyword.fetch!(opts, :name))

  defp resolve_component(name) when is_atom(name), do: VisionCore.Components.start(name, [])

  defp resolve_component({name, opts}) when is_atom(name),
    do: VisionCore.Components.start(name, opts)

  # Without a selected vehicle the cluster has no peers to probe for.
  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      vehicle_module -> [{OvcsBus.Cluster, vehicle: vehicle_module}]
    end
  end
end
