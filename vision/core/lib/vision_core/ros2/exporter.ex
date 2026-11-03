defmodule VisionCore.Ros2.Exporter do
  @moduledoc """
  Publishes the vision unit on ROS 2, through
  `VisionCore.Ros2.ZenohClient`: a `VisionCore.Exporter`, which
  `VisionCore.Exporters` runs under a supervisor and restart budget of
  its own.

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

  Each publishes only when its options are given. The messages are
  built by plain functions; this module sends them with its `:publish`
  function.

  `VisionCore.Stereo.Supervisor.reload_calibration/3` tells it, through
  `reload_calibration/2`, that a calibration was committed, and the
  camera info follows.

  ## Options

    * `:stereo` — the stereo unit's options, see
      `VisionCore.Ros2.Exporter.Stereo`, with the `:driver`, `:fps` and
      each side's `:sync` that `VisionCore.Ros2.Exporter.Diagnostics`
      reads.
    * `:detections` — see `VisionCore.Ros2.Exporter.Detections`.
    * `:heartbeat` — `:interval_ms` (`1_000`), the time between two
      heartbeats.
    * `:node_name` (the node name of the active `VisionCore.Config`) —
      the node the heartbeat names.
    * `:publish` (`&VisionCore.Ros2.ZenohClient.publish/4`) — sends one
      message: called with its topic, its module, the message and `[]`.
    * `:jpeg_codec` (`VisionCore.Jpeg`) — the `VisionCore.Jpeg` instance
      the raw and rectified images are encoded on, which
      `VisionCore.Exporters` gives.
    * `:name` — registers the exporter's runner; `reload_calibration/2`
      sends to this module's name by default.
  """
  @behaviour VisionCore.Exporter

  require Logger

  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Exporter.{Detections, Diagnostics, Stereo}
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Stereo.{Pair, StageTimer}

  @heartbeat_topic "ovcs_heartbeat"
  @default_heartbeat_interval_ms 1_000

  @doc """
  Tells the exporter registered as `server` that a calibration was
  committed: it reads each side's camera info again, from
  `:left_calibration_path` / `:right_calibration_path` in `paths` when
  given. Does nothing when no exporter runs under that name.
  """
  @spec reload_calibration(GenServer.server(), keyword()) :: :ok
  def reload_calibration(server \\ __MODULE__, paths) do
    if exporter = GenServer.whereis(server), do: send(exporter, {:reload_calibration, paths})
    :ok
  end

  @doc "The heartbeat numbered `counter` of the node `node_name`, sent at `system_time_ms`."
  @spec heartbeat_message(pos_integer(), String.t(), integer()) :: struct()
  def heartbeat_message(counter, node_name, system_time_ms),
    do: %StringMessage{data: "#{node_name} heartbeat #{counter} @ #{system_time_ms}"}

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
    case options[:stereo] do
      nil -> []
      stereo -> [{Diagnostics, Keyword.put(stereo, :publish, publish_function(options))}]
    end
  end

  @impl VisionCore.Exporter
  def init(options) do
    state = %{
      publish: publish_function(options),
      jpeg_codec: Keyword.get(options, :jpeg_codec, VisionCore.Jpeg),
      heartbeat: options[:heartbeat] && start_heartbeat(options),
      stereo: options[:stereo] && start_stereo(options[:stereo]),
      detections: options[:detections] && start_detections(options[:detections]),
      drawn: 0,
      telemetry: StageTimer.new(window: 30, label: "publisher"),
      last_pair_at_ns: nil
    }

    if state.heartbeat, do: Process.send_after(self(), :heartbeat, state.heartbeat.interval_ms)
    {:ok, state}
  end

  defp publish_function(options), do: Keyword.get(options, :publish, &ZenohClient.publish/4)

  defp start_heartbeat(options) do
    interval_ms = Keyword.get(options[:heartbeat], :interval_ms, @default_heartbeat_interval_ms)

    node_name =
      Keyword.get_lazy(options, :node_name, fn ->
        ZenohClient.configured_node_name(VisionCore.Application.active_config())
      end)

    Logger.info("#{__MODULE__} ticking a heartbeat on #{@heartbeat_topic} every #{interval_ms}ms")
    %{interval_ms: interval_ms, node_name: node_name, counter: 0}
  end

  defp start_stereo(options) do
    stereo = Stereo.new(options)

    Logger.info(
      "#{__MODULE__} publishing #{inspect(options[:driver])}[left], " <>
        "#{inspect(options[:driver])}[right], #{stereo.disparity_topic} and #{stereo.depth_topic}"
    )

    stereo
  end

  defp start_detections(options) do
    detections = Detections.new(options)

    Logger.info(
      "#{__MODULE__} publishing markers on #{detections.markers_topic} and " <>
        "detections on #{detections.detections_topic} (frame #{detections.frame_id})"
    )

    detections
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

    {publish_ns, side_state} =
      measure_ns(fn ->
        {messages, side_state} =
          Stereo.frame_messages(
            frame,
            state.stereo.sides[label],
            state.stereo,
            System.monotonic_time(:millisecond),
            &Frame.to_jpeg(&1, state.jpeg_codec)
          )

        publish_all(messages, state)
        side_state
      end)

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

  def handle_info({:reload_calibration, paths}, %{stereo: stereo} = state) when stereo != nil,
    do: {:ok, %{state | stereo: Stereo.reload(stereo, paths)}}

  def handle_info(_message, state), do: {:ok, state}

  defp frame_telemetry(:left), do: {:pub_left, :frames_left}
  defp frame_telemetry(:right), do: {:pub_right, :frames_right}

  defp encode_image(image, jpeg_codec),
    do: VisionCore.Jpeg.encode_tensor(image, codec: jpeg_codec)

  defp publish_all(messages, state), do: Enum.each(messages, &publish(state, &1))

  defp publish(state, {topic, module, message}), do: state.publish.(topic, module, message, [])

  defp measure_ns(fun) do
    start_ns = System.monotonic_time(:nanosecond)
    return_value = fun.()
    {System.monotonic_time(:nanosecond) - start_ns, return_value}
  end
end
