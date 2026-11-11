defmodule VisionCore.Ros2.Exporter do
  @moduledoc """
  Publishes the vision unit on ROS 2, through
  `Ros2Zenoh.Client`: a `VisionCore.Exporter`, which
  `VisionCore.Exporters` runs under a supervisor and restart budget of
  its own, and lists as `ros2`, "ROS 2".

    * The stereo unit's raw images and camera info as its cameras
      deliver them, and the disparity, depth and point cloud of each
      pair (`VisionCore.Ros2.Exporter.Stereo`).
    * What the stereo unit's cameras actually do, and their sync
      (`VisionCore.Ros2.Exporter.Diagnostics`, a helper under the
      exporter's supervisor).
    * Each detection pipeline's detections, as markers, `vision_msgs`
      and an overlay on the left raw image, or on a camera source the
      camera's (`VisionCore.Ros2.Exporter.Detections`).
    * Each camera of its own's image, camera info and pose relative to
      the stereo pair (`VisionCore.Ros2.Exporter.Camera`).
    * A heartbeat, `std_msgs/String` on `ovcs_heartbeat`, so consumers
      see the unit alive even when no other topic flows. Its data names
      the node, so nodes sharing the topic tell themselves apart.

  Each publishes only when its options are given. A message is stamped
  with the frame id its camera frame or pair carries. The messages are
  built by plain functions; this module sends them with its `:publish`
  function.

  It needs the ROS 2 link, the `ros2:` section of the configuration:
  without it, it is not started (`check/1`), nor when it publishes a
  stereo unit the configuration has none of, or one whose cameras it
  cannot read, nor with a `cameras:` option it does not take or a name
  no camera of the configuration has. Its status is the link's:
  connected while the Zenoh session is open.

  ## The stereo unit

  It reads the stereo unit's cameras in the configuration
  (`VisionCore.Stereo.Supervisor.camera_options/1`) at each start of its
  runner: their driver and rate for the diagnostics, their capture size,
  and each side's calibration for the camera info, the calibration a
  commit stored first, as the stereo unit reads it. A restart publishes
  the calibration in force.

  It answers `cameracalibrator`'s COMMIT for each side with a
  calibration path: a `VisionCore.Ros2.Services.SetCameraInfoServer`, a
  helper under its supervisor, writes the calibration to the stereo
  unit's store, or without one to the side's calibration path, has the
  stereo unit reload it (`VisionCore.Stereo.Supervisor`), and tells the
  exporter, which reads its camera info again.

  ## Cameras of their own

  It reads each camera's settings in the configuration
  (`VisionCore.Camera.Unit.settings/1`) at each start of its runner,
  and answers `set_camera_info` on `<prefix>/<name>/set_camera_info`
  for each camera with a calibration path or a store: a
  `VisionCore.Ros2.Services.SetCameraInfoServer` writes the calibration
  to the camera's store, or without one to its `:calibration`, and
  tells the exporter, which reads its camera info again.

  The pose of each camera that has one goes out as a static transform,
  `tf2_msgs/TFMessage` on `/tf_static`, from the stereo unit's left
  optical frame, the frame of its depth, to the camera's `frame_id`.
  The link publishes volatile, so a viewer that joins later would never
  see a transform sent once: it is sent again every second. No
  transform without a stereo unit in the configuration.

  ## Options

    * `:stereo` — publishes the stereo unit; `VisionCore.Ros2.Exporter.Stereo`
      documents its options: `:topic_prefix`, the stereo unit's
      `:prefix` by default, the `:publish_*` switches,
      `:raw_image_max_hz` and `:camera_info_interval_frames`.
    * `:detections` — publishes the detections of each pipeline its
      `:pipelines` list (`[:detection]`, the default pipeline), each on
      topics and in a marker namespace of its own;
      `VisionCore.Ros2.Exporter.Detections` documents its other options
      and the topics, its `:topic_prefix` the stereo unit's `:prefix` by
      default.
    * `:cameras` — publishes the cameras of their own its `:names` list,
      every camera of the configuration by default:
      `:topic_prefix`, the stereo unit's `:prefix` by default, else
      `"stereo"`; `:raw_image_max_hz` (10), the most images a second per
      camera for frames it encodes, JPEG frames going out as they arrive;
      `:camera_info_interval_frames` (30), the camera info every Nth frame.
    * `:heartbeat` — publishes the heartbeat; `:interval_ms` (`1_000`),
      the time between two heartbeats.
    * `:node_name` (the node name of the configuration's `ros2:`) —
      the node the heartbeat names.
    * `:publish` (`&VisionCore.Ros2.Topics.publish/4`) — sends one
      message: called with its topic, its module, the message and `[]`.
    * `:register_service` (`&Ros2Zenoh.Client.register_service/3`)
      — registers each side's and camera's `set_camera_info` service.
    * `:jpeg_codec` (`VisionCore.Jpeg`) and `:config` (the active
      `VisionCore.Config`) — the `VisionCore.Jpeg` instance the raw and
      rectified images are encoded on, and the configuration, which
      `VisionCore.Exporters` gives.
  """
  @behaviour VisionCore.Exporter

  require Logger

  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias Ros2Zenoh.Tf2Msgs.Msg.TFMessage
  alias VisionCore.Camera.{Frame, Unit}
  alias VisionCore.Detection
  alias VisionCore.Ros2.Exporter.{Camera, Detections, Diagnostics, Stereo}
  alias VisionCore.Ros2.Services.SetCameraInfoServer
  alias VisionCore.Ros2.{Node, Stamp, Topics}
  alias VisionCore.Stereo.{Pair, StageTimer}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @heartbeat_topic "ovcs_heartbeat"
  @default_heartbeat_interval_ms 1_000
  @default_prefix "stereo"
  @transform_topic "/tf_static"
  @transform_interval_ms 1_000
  @camera_options [:names, :topic_prefix, :raw_image_max_hz, :camera_info_interval_frames]

  @doc "The heartbeat numbered `counter` of the node `node_name`, sent at `system_time_ms`."
  @spec heartbeat_message(pos_integer(), String.t(), integer()) :: struct()
  def heartbeat_message(counter, node_name, system_time_ms),
    do: %StringMessage{data: "#{node_name} heartbeat #{counter} @ #{system_time_ms}"}

  @impl VisionCore.Exporter
  def describe(_options), do: %{id: :ros2, name: "ROS 2"}

  @impl VisionCore.Exporter
  def check(options) do
    config = config(options)

    with :ok <- check_link(config),
         :ok <- check_stereo(options[:stereo], config) do
      check_cameras(options[:cameras], config)
    end
  end

  defp check_link(%VisionCore.Config{ros2: nil}),
    do:
      {:error,
       "the vision configuration has no ros2: section, the ROS 2 link it publishes through"}

  defp check_link(_config), do: :ok

  defp check_stereo(nil, _config), do: :ok

  defp check_stereo(_stereo_options, config) do
    case StereoSupervisor.camera_options(config) do
      {:ok, _cameras} -> :ok
      {:error, reason} -> {:error, "cannot publish the stereo unit: #{reason}"}
    end
  end

  defp check_cameras(nil, _config), do: :ok

  defp check_cameras(camera_options, config) do
    names = for {name, _driver, _server} <- Unit.cameras(config), do: name

    cond do
      not (is_list(camera_options) and Keyword.keyword?(camera_options)) ->
        {:error, "its cameras: is not a keyword list: #{inspect(camera_options)}"}

      (unknown = Keyword.keys(camera_options) -- @camera_options) != [] ->
        {:error, "its cameras: has no option #{Enum.map_join(unknown, ", ", &inspect/1)}"}

      not is_list(listed = Keyword.get(camera_options, :names, [])) ->
        {:error, "its cameras: names: is not a list of camera names: #{inspect(listed)}"}

      (missing = Keyword.get(camera_options, :names, []) -- names) != [] ->
        {:error,
         "its cameras: names #{Enum.map_join(missing, ", ", &inspect/1)}, " <>
           "which is no camera of the configuration"}

      true ->
        :ok
    end
  end

  @impl VisionCore.Exporter
  def outputs(options) do
    stereo =
      if options[:stereo],
        do: [:stereo_pair, {:camera_frame, :left}, {:camera_frame, :right}],
        else: []

    stereo ++
      Enum.map(detection_pipelines(options[:detections]), &Detection.output/1) ++
      Enum.map(published_camera_names(options), &{:camera_frame, &1})
  end

  # Without reading the cameras' files: `outputs/1` runs at every listing.
  defp published_camera_names(options) do
    case options[:cameras] do
      nil ->
        []

      camera_options ->
        names = for {name, _driver, _server} <- Unit.cameras(config(options)), do: name
        Enum.filter(names, &(&1 in Keyword.get(camera_options, :names, names)))
    end
  end

  # The settings of the cameras that `cameras:` publishes.
  defp published_cameras(options) do
    case published_camera_names(options) do
      [] -> []
      names -> options |> config() |> Unit.settings() |> Enum.filter(&(&1.name in names))
    end
  end

  defp camera_topic_prefix(options) do
    Keyword.get_lazy(options[:cameras], :topic_prefix, fn ->
      options |> config() |> StereoSupervisor.camera_options() |> unit_prefix()
    end)
  end

  defp detection_pipelines(nil), do: []

  defp detection_pipelines(detections_options),
    do: Keyword.get(detections_options, :pipelines, [:detection])

  @impl VisionCore.Exporter
  def children(options), do: stereo_children(options) ++ camera_children(options)

  defp stereo_children(options) do
    with stereo_options when is_list(stereo_options) <- options[:stereo],
         {:ok, cameras} <- StereoSupervisor.camera_options(config(options)) do
      topic_prefix = Keyword.get(stereo_options, :topic_prefix, cameras[:prefix])

      diagnostics =
        Keyword.take(cameras, [:driver, :fps, :left, :right]) ++
          [topic_prefix: topic_prefix, publish: publish_function(options)]

      [{Diagnostics, diagnostics} | set_camera_info_children(cameras, topic_prefix, options)]
    else
      _nothing_to_publish -> []
    end
  end

  defp set_camera_info_children(cameras, topic_prefix, options) do
    register_service =
      Keyword.get(options, :register_service, &Ros2Zenoh.Client.register_service/3)

    for {side, path} <- writable_calibration_paths(cameras) do
      Supervisor.child_spec(
        {SetCameraInfoServer,
         service_name: set_camera_info_service(topic_prefix, side),
         calibration_path: path,
         camera_name: "#{cameras[:prefix]}_#{side}",
         reload: reload_callback(cameras),
         register_service: register_service},
        id: {SetCameraInfoServer, side}
      )
    end
  end

  # Where a commit writes each side's calibration: the stereo unit's store, else its calibration path.
  defp writable_calibration_paths(cameras) do
    for side <- [:left, :right],
        path =
          Keyword.get(cameras[side], :calibration_store_path, cameras[side][:calibration_path]),
        do: {side, path}
  end

  defp set_camera_info_service(topic_prefix, side), do: "#{topic_prefix}/#{side}/set_camera_info"

  defp camera_children(options) do
    register_service =
      Keyword.get(options, :register_service, &Ros2Zenoh.Client.register_service/3)

    for settings <- published_cameras(options),
        path = writable_calibration_path(settings) do
      Supervisor.child_spec(
        {SetCameraInfoServer,
         service_name: Camera.service_name(camera_topic_prefix(options), settings.name),
         calibration_path: path,
         camera_name: Atom.to_string(settings.name),
         reload: nil,
         register_service: register_service},
        id: {SetCameraInfoServer, settings.name}
      )
    end
  end

  # Where a commit writes the camera's calibration: its store, else its calibration path.
  defp writable_calibration_path(settings),
    do: settings.calibration_store_path || settings.calibration_path

  # Once both sides are stored the stereo unit reloads from its store; without one, from its own paths.
  defp reload_callback(cameras) do
    pipeline = VisionCore.Stereo.Pipeline

    case {cameras[:left][:calibration_store_path], cameras[:right][:calibration_store_path]} do
      {nil, nil} ->
        {StereoSupervisor, :reload_calibration, [pipeline, cameras[:prefix]]}

      {left_store, right_store} ->
        {StereoSupervisor, :reload_stored_calibration,
         [pipeline, cameras[:prefix], left_store, right_store]}
    end
  end

  @impl VisionCore.Exporter
  def init(options) do
    config = config(options)
    cameras = StereoSupervisor.camera_options(config)

    with {:ok, stereo} <- start_stereo(options[:stereo], cameras) do
      state = %{
        config: config,
        publish: publish_function(options),
        jpeg_codec: Keyword.get(options, :jpeg_codec, VisionCore.Jpeg),
        heartbeat: options[:heartbeat] && start_heartbeat(options, config),
        stereo: stereo,
        detections: start_detections(options[:detections], cameras),
        cameras: start_cameras(options),
        transform_parent_frame_id: left_frame_id(cameras),
        telemetry: StageTimer.new(window: 30, label: "publisher"),
        last_pair_at_ns: nil
      }

      if stereo, do: notify_on_commit(options[:stereo], cameras)
      notify_cameras_on_commit(state.cameras)
      if transform_message(state), do: send(self(), :publish_transforms)
      if state.heartbeat, do: Process.send_after(self(), :heartbeat, state.heartbeat.interval_ms)
      {:ok, state}
    end
  end

  defp config(options) do
    Keyword.get_lazy(options, :config, &VisionCore.Application.active_config/0) ||
      %VisionCore.Config{}
  end

  defp publish_function(options), do: Keyword.get(options, :publish, &Topics.publish/4)

  defp start_heartbeat(options, config) do
    interval_ms = Keyword.get(options[:heartbeat], :interval_ms, @default_heartbeat_interval_ms)

    node_name =
      Keyword.get_lazy(options, :node_name, fn -> Node.configured_node_name(config) end)

    Logger.info("#{__MODULE__} ticking a heartbeat on #{@heartbeat_topic} every #{interval_ms}ms")
    %{interval_ms: interval_ms, node_name: node_name, counter: 0}
  end

  defp start_stereo(nil, _cameras), do: {:ok, nil}

  defp start_stereo(_options, {:error, reason}),
    do: {:error, "cannot publish the stereo unit: #{reason}"}

  defp start_stereo(options, {:ok, cameras}) do
    stereo =
      cameras
      |> Keyword.merge(options)
      |> Keyword.put_new(:topic_prefix, cameras[:prefix])
      |> Stereo.new()

    Logger.info(
      "#{__MODULE__} publishing #{inspect(cameras[:driver])}[left], " <>
        "#{inspect(cameras[:driver])}[right], #{stereo.disparity_topic} and #{stereo.depth_topic}"
    )

    {:ok, stereo}
  end

  # The servers outlive the runner's restarts: each start tells them where to send.
  defp notify_on_commit(stereo_options, {:ok, cameras}) do
    topic_prefix = Keyword.get(stereo_options, :topic_prefix, cameras[:prefix])

    for {side, _path} <- writable_calibration_paths(cameras) do
      topic_prefix
      |> set_camera_info_service(side)
      |> SetCameraInfoServer.name_for()
      |> SetCameraInfoServer.notify(self())
    end
  end

  # Each pipeline's settings and the count of its markers drawn last, by its output.
  defp start_detections(options, cameras) do
    Map.new(detection_pipelines(options), fn pipeline ->
      settings =
        options
        |> Keyword.delete(:pipelines)
        |> Keyword.put(:pipeline, pipeline)
        |> Keyword.put_new(:topic_prefix, unit_prefix(cameras))
        |> Detections.new()

      Logger.info(
        "#{__MODULE__} publishing markers on #{settings.markers_topic} and " <>
          "detections on #{settings.detections_topic}"
      )

      {Detection.output(pipeline), %{settings: settings, drawn: 0}}
    end)
  end

  defp unit_prefix({:ok, cameras}), do: cameras[:prefix]
  defp unit_prefix({:error, _reason}), do: @default_prefix

  # Each published camera of its own, by name.
  defp start_cameras(options) do
    case published_cameras(options) do
      [] ->
        %{}

      published ->
        camera_options =
          options[:cameras]
          |> Keyword.delete(:names)
          |> Keyword.put(:topic_prefix, camera_topic_prefix(options))

        Map.new(published, fn settings ->
          camera = Camera.new(settings, camera_options)
          Logger.info("#{__MODULE__} publishing camera #{settings.name} on #{camera.image_topic}")
          {settings.name, camera}
        end)
    end
  end

  defp notify_cameras_on_commit(cameras) do
    for {_name, camera} <- cameras do
      camera.service_name |> SetCameraInfoServer.name_for() |> SetCameraInfoServer.notify(self())
    end
  end

  defp left_frame_id({:ok, cameras}), do: cameras[:left][:frame_id]
  defp left_frame_id({:error, _reason}), do: nil

  defp transform_message(%{transform_parent_frame_id: nil}), do: nil

  defp transform_message(state) do
    stamp = Stamp.stamp_from_monotonic(System.monotonic_time(:nanosecond))
    Camera.transform_message(Map.values(state.cameras), state.transform_parent_frame_id, stamp)
  end

  @impl VisionCore.Exporter
  def status(_state) do
    if Ros2Zenoh.Client.session_open?(), do: {:ok, "Connected"}, else: {:warning, "Disconnected"}
  end

  @impl VisionCore.Exporter
  def handle_output(:stereo_pair, %Pair{} = pair, state) do
    now_ns = System.monotonic_time(:nanosecond)

    {publish_ns, :ok} =
      measure_ns(fn ->
        pair
        |> Stereo.pair_messages(state.stereo, &encode_image(&1, state.jpeg_codec))
        |> publish_all(state)
      end)

    pair_interval_ns = if state.last_pair_at_ns, do: now_ns - state.last_pair_at_ns, else: 0

    telemetry =
      state.telemetry
      |> StageTimer.record(:pub_stereo, publish_ns)
      |> StageTimer.record(:wall, pair_interval_ns)
      |> StageTimer.tick()

    {:ok, %{state | telemetry: telemetry, last_pair_at_ns: now_ns}}
  end

  def handle_output({:camera_frame, name}, %Frame{} = frame, state)
      when is_map_key(state.cameras, name) do
    {messages, camera} =
      Camera.frame_messages(
        frame,
        state.cameras[name],
        System.monotonic_time(:millisecond),
        &Frame.to_jpeg(&1, state.jpeg_codec)
      )

    publish_all(messages, state)
    {:ok, put_in(state.cameras[name], camera)}
  end

  def handle_output({:camera_frame, side}, %Frame{} = frame, state) do
    label = Atom.to_string(side)
    {publish_stage, frames_counter} = frame_telemetry(side)
    image_topic = state.stereo.sides[label].image_topic

    # :pub_left and :pub_right time the raw image alone; the camera info goes out after.
    {publish_ns, {camera_info, side_state}} =
      measure_ns(fn ->
        {messages, side_state} =
          Stereo.frame_messages(
            frame,
            state.stereo.sides[label],
            state.stereo,
            System.monotonic_time(:millisecond),
            &Frame.to_jpeg(&1, state.jpeg_codec)
          )

        {image, camera_info} = Enum.split_with(messages, &(elem(&1, 0) == image_topic))
        publish_all(image, state)
        {camera_info, side_state}
      end)

    publish_all(camera_info, state)

    telemetry =
      state.telemetry
      |> StageTimer.record(publish_stage, publish_ns)
      |> StageTimer.bump(frames_counter)

    state = put_in(state.stereo.sides[label], side_state)
    {:ok, %{state | telemetry: telemetry}}
  end

  def handle_output(output, {source, detections}, state)
      when is_map_key(state.detections, output) do
    %{settings: settings, drawn: drawn} = state.detections[output]

    detections
    |> Detections.messages(source, settings, drawn)
    |> publish_all(state)

    {:ok, put_in(state.detections[output].drawn, Detections.drawn(detections))}
  end

  @impl VisionCore.Exporter
  def handle_info(:heartbeat, %{heartbeat: heartbeat} = state) do
    counter = heartbeat.counter + 1
    message = heartbeat_message(counter, heartbeat.node_name, System.system_time(:millisecond))
    publish(state, {@heartbeat_topic, StringMessage, message})
    Process.send_after(self(), :heartbeat, heartbeat.interval_ms)
    {:ok, %{state | heartbeat: %{heartbeat | counter: counter}}}
  end

  def handle_info(:publish_transforms, state) do
    case transform_message(state) do
      nil -> :ok
      message -> publish(state, {@transform_topic, TFMessage, message})
    end

    Process.send_after(self(), :publish_transforms, @transform_interval_ms)
    {:ok, state}
  end

  def handle_info({:calibration_committed, service_name}, state) do
    case Enum.find(Map.values(state.cameras), &(&1.service_name == service_name)) do
      nil -> reload_stereo_calibration(state)
      camera -> {:ok, put_in(state.cameras[camera.name], reload_camera(camera, state.config))}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp reload_camera(camera, config) do
    case Enum.find(Unit.settings(config), &(&1.name == camera.name)) do
      nil -> camera
      settings -> Camera.reload(camera, settings.calibration_path)
    end
  end

  defp reload_stereo_calibration(%{stereo: nil} = state), do: {:ok, state}

  defp reload_stereo_calibration(%{stereo: stereo} = state) do
    case StereoSupervisor.camera_options(state.config) do
      {:ok, cameras} ->
        paths = [
          left_calibration_path: cameras[:left][:calibration_path],
          right_calibration_path: cameras[:right][:calibration_path]
        ]

        {:ok, %{state | stereo: Stereo.reload(stereo, paths)}}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp frame_telemetry(:left), do: {:pub_left, :frames_left}
  defp frame_telemetry(:right), do: {:pub_right, :frames_right}

  defp encode_image(image, jpeg_codec),
    do: VisionCore.Jpeg.encode_tensor(image, codec: jpeg_codec)

  defp publish_all(messages, state), do: Enum.each(messages, &publish(state, &1))

  defp publish(state, {topic, module, message}), do: publish(state, {topic, module, message, []})

  defp publish(state, {topic, module, message, options}),
    do: state.publish.(topic, module, message, options)

  defp measure_ns(fun) do
    start_ns = System.monotonic_time(:nanosecond)
    return_value = fun.()
    {System.monotonic_time(:nanosecond) - start_ns, return_value}
  end
end
