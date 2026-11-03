defmodule VisionCore.Ros2.Exporter do
  @moduledoc """
  Publishes the vision unit on ROS 2, through
  `VisionCore.Ros2.ZenohClient`: a `VisionCore.Exporter`, which
  `VisionCore.Exporters` runs under a supervisor and restart budget of
  its own, and lists as `ros2`, "ROS 2".

    * The stereo unit's raw images and camera info as its cameras
      deliver them, and the disparity, depth and point cloud of each
      pair (`VisionCore.Ros2.Exporter.Stereo`).
    * What the stereo unit's cameras actually do, and their sync
      (`VisionCore.Ros2.Exporter.Diagnostics`, a helper under the
      exporter's supervisor).
    * The detections, as markers, `vision_msgs` and an overlay on the
      left raw image (`VisionCore.Ros2.Exporter.Detections`).
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
  cannot read. Its status is the link's: connected while the Zenoh
  session is open.

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

  ## Options

    * `:stereo` — publishes the stereo unit; `VisionCore.Ros2.Exporter.Stereo`
      documents its options: `:topic_prefix`, the stereo unit's
      `:prefix` by default, the `:publish_*` switches,
      `:raw_image_max_hz` and `:camera_info_interval_frames`.
    * `:detections` — publishes the detections;
      `VisionCore.Ros2.Exporter.Detections` documents its options, its
      `:topic_prefix` the stereo unit's `:prefix` by default.
    * `:heartbeat` — publishes the heartbeat; `:interval_ms` (`1_000`),
      the time between two heartbeats.
    * `:node_name` (the node name of the configuration's `ros2:`) —
      the node the heartbeat names.
    * `:publish` (`&VisionCore.Ros2.ZenohClient.publish/4`) — sends one
      message: called with its topic, its module, the message and `[]`.
    * `:register_service` (`&VisionCore.Ros2.ZenohClient.register_service/3`)
      — registers each side's `set_camera_info` service.
    * `:jpeg_codec` (`VisionCore.Jpeg`) and `:config` (the active
      `VisionCore.Config`) — the `VisionCore.Jpeg` instance the raw and
      rectified images are encoded on, and the configuration, which
      `VisionCore.Exporters` gives.
  """
  @behaviour VisionCore.Exporter

  require Logger

  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Exporter.{Detections, Diagnostics, Stereo}
  alias VisionCore.Ros2.Services.SetCameraInfoServer
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Stereo.{Pair, StageTimer}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @heartbeat_topic "ovcs_heartbeat"
  @default_heartbeat_interval_ms 1_000
  @default_prefix "stereo"

  @doc "The heartbeat numbered `counter` of the node `node_name`, sent at `system_time_ms`."
  @spec heartbeat_message(pos_integer(), String.t(), integer()) :: struct()
  def heartbeat_message(counter, node_name, system_time_ms),
    do: %StringMessage{data: "#{node_name} heartbeat #{counter} @ #{system_time_ms}"}

  @impl VisionCore.Exporter
  def describe(_options), do: %{id: :ros2, name: "ROS 2"}

  @impl VisionCore.Exporter
  def check(options) do
    config = config(options)

    cond do
      config.ros2 == nil ->
        {:error,
         "the vision configuration has no ros2: section, the ROS 2 link it publishes through"}

      options[:stereo] == nil ->
        :ok

      true ->
        case StereoSupervisor.camera_options(config) do
          {:ok, _cameras} -> :ok
          {:error, reason} -> {:error, "cannot publish the stereo unit: #{reason}"}
        end
    end
  end

  @impl VisionCore.Exporter
  def outputs(options) do
    stereo =
      if options[:stereo],
        do: [:stereo_pair, {:camera_frame, :left}, {:camera_frame, :right}],
        else: []

    stereo ++ if options[:detections], do: [:detections], else: []
  end

  @impl VisionCore.Exporter
  def children(options) do
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
    register_service = Keyword.get(options, :register_service, &ZenohClient.register_service/3)

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
        detections: options[:detections] && start_detections(options[:detections], cameras),
        drawn: 0,
        telemetry: StageTimer.new(window: 30, label: "publisher"),
        last_pair_at_ns: nil
      }

      if stereo, do: notify_on_commit(options[:stereo], cameras)
      if state.heartbeat, do: Process.send_after(self(), :heartbeat, state.heartbeat.interval_ms)
      {:ok, state}
    end
  end

  defp config(options) do
    Keyword.get_lazy(options, :config, &VisionCore.Application.active_config/0) ||
      %VisionCore.Config{}
  end

  defp publish_function(options), do: Keyword.get(options, :publish, &ZenohClient.publish/4)

  defp start_heartbeat(options, config) do
    interval_ms = Keyword.get(options[:heartbeat], :interval_ms, @default_heartbeat_interval_ms)

    node_name =
      Keyword.get_lazy(options, :node_name, fn -> ZenohClient.configured_node_name(config) end)

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

  defp start_detections(options, cameras) do
    detections =
      options
      |> Keyword.put_new(:topic_prefix, unit_prefix(cameras))
      |> Detections.new()

    Logger.info(
      "#{__MODULE__} publishing markers on #{detections.markers_topic} and " <>
        "detections on #{detections.detections_topic}"
    )

    detections
  end

  defp unit_prefix({:ok, cameras}), do: cameras[:prefix]
  defp unit_prefix({:error, _reason}), do: @default_prefix

  @impl VisionCore.Exporter
  def status(_state) do
    if ZenohClient.session_open?(), do: {:ok, "Connected"}, else: {:warning, "Disconnected"}
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

  def handle_output(:detections, {%Pair{} = pair, detections}, state) do
    detections
    |> Detections.messages(pair, state.detections, state.drawn)
    |> publish_all(state)

    {:ok, %{state | drawn: length(detections)}}
  end

  @impl VisionCore.Exporter
  def handle_info(:heartbeat, %{heartbeat: heartbeat} = state) do
    counter = heartbeat.counter + 1
    message = heartbeat_message(counter, heartbeat.node_name, System.system_time(:millisecond))
    publish(state, {@heartbeat_topic, StringMessage, message})
    Process.send_after(self(), :heartbeat, heartbeat.interval_ms)
    {:ok, %{state | heartbeat: %{heartbeat | counter: counter}}}
  end

  def handle_info({:calibration_committed, _service_name}, %{stereo: stereo} = state)
      when stereo != nil do
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

  def handle_info(_message, state), do: {:ok, state}

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
