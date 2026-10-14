defmodule RosBridge.Camera.Zenoh do
  @moduledoc """
  A camera that is somewhere else: subscribes to a ROS
  `sensor_msgs/CompressedImage` topic and hands the frames on as if it
  had captured them.

  This is what lets the whole perception stack run against Gazebo. The
  stereo supervisor, the SGBM backend, the publishers and the Hailo
  detector see `{:camera_frame, %Frame{}}` casts and cannot tell
  whether the pixels came from a sensor or a simulator — which is the
  point. Swapping `driver: RosBridge.Camera.LibCamera` for this module
  is the entire difference between running on the car and running
  against a simulated one.

  ## Options

    * `:label` (required) — `"left"` / `"right"`, as for every driver.
    * `:topic` (required) — the ROS topic to consume, e.g.
      `"/stereo/left/image_raw/compressed"`.

  `:width`, `:height` and `:fps` are accepted and ignored: the
  publisher decides the format, and quietly resizing here would hide a
  simulator configured differently from the vehicle rather than
  surface it.

  ## Compressed, not raw

  The topic carries JPEG, and that is not incidental. Raw frames
  outrun what a Zenoh subscriber can drain; the transport then drops
  what the link will not carry, and the failure looks like a dead topic
  rather than a saturated one. Compression belongs upstream of the
  fabric, which is also what the real vehicle does.

  ## Time

  `Frame.capture_ns` means Erlang monotonic time everywhere in this
  bridge, so the stamp a frame carries, on the simulator's clock, is
  converted back through `RosBridge.Timing.monotonic_from_ros_time/1`. Both
  sides of a pair carry the same render stamp, so the stereo
  publisher pairs them exactly; their arrival times differ by tens of
  milliseconds, enough to pair a frame with its neighbour's, which
  reads as phantom depth once the car moves. Until `RosBridge.Clock`
  has seen `/clock` there is no conversion, and frames are stamped on
  arrival.
  """
  @behaviour RosBridge.Camera

  use GenServer

  require Logger

  alias Ros2.SensorMsgs.Msg.CompressedImage
  alias RosBridge.Camera.Frame
  alias RosBridge.Timing

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    GenServer.start_link(__MODULE__, opts, name: name_for(label))
  end

  @doc "The registered name of the driver for `label`."
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @impl RosBridge.Camera
  def register_listener(server, listener) do
    GenServer.cast(server, {:register_listener, listener})
  end

  @impl RosBridge.Camera
  def enable(_server), do: :ok

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    topic = Keyword.fetch!(opts, :topic)

    # Subscribing from `init/1` is safe: ZenohClient records the
    # subscription and declares it on the next successful connect, so
    # a camera that starts before the session is up still works.
    :ok = RosBridge.ZenohClient.subscribe(topic, CompressedImage)

    Logger.info("#{__MODULE__}[#{label}] consuming #{topic}")

    {:ok, %{label: label, topic: topic, listeners: [], frame_count: 0}}
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl GenServer
  def handle_info({:ros_message, {_key_expr, %CompressedImage{} = image}}, state) do
    case decode_dimensions(image.data) do
      {:ok, width, height} ->
        frame = %Frame{
          label: state.label,
          width: width,
          height: height,
          capture_ns: capture_ns(image),
          jpeg: image.data
        }

        Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))
        {:noreply, %{state | frame_count: state.frame_count + 1}}

      :error ->
        # A frame whose dimensions cannot be read is not one the
        # stereo backend can pair or rectify, so it is dropped rather
        # than passed on with guessed values.
        Logger.warning(
          "#{__MODULE__}[#{state.label}] dropping frame: not a readable JPEG " <>
            "(#{byte_size(image.data)} bytes, format #{inspect(image.format)})"
        )

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp capture_ns(%CompressedImage{header: %{stamp: %{sec: sec, nanosec: nanosec}}}) do
    if RosBridge.Clock.following?(),
      do: Timing.monotonic_from_ros_time(sec * 1_000_000_000 + nanosec),
      else: System.monotonic_time(:nanosecond)
  end

  @doc """
  Read a JPEG's pixel dimensions from its header.

  `CompressedImage` carries no width or height — unlike `Image`, which
  does — so the only place the dimensions exist is the JPEG itself.
  Reading them from the SOF marker avoids decoding the whole frame
  here just to fill in two integers the backend rediscovers when it
  decodes for real.

  Segments are `FF <marker> <2-byte length> <payload>`; SOF0/1/2 and
  the other non-differential SOF markers carry height and width at a
  fixed offset. FFD8/FFD9 and the FFD0-FFD7 restart markers are
  standalone and carry no length.

  Public because it is worth testing on its own: a wrong answer here
  hands the stereo backend a frame whose declared size disagrees with
  its pixels.
  """
  @spec decode_dimensions(binary()) :: {:ok, pos_integer(), pos_integer()} | :error
  def decode_dimensions(<<0xFF, 0xD8, rest::binary>>), do: scan_segments(rest)
  def decode_dimensions(_), do: :error

  defp scan_segments(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9 do
    scan_segments(rest)
  end

  defp scan_segments(<<0xFF, marker, _length::big-16, rest::binary>>)
       when marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB] do
    case rest do
      <<_precision, height::big-16, width::big-16, _::binary>> when width > 0 and height > 0 ->
        {:ok, width, height}

      _ ->
        :error
    end
  end

  defp scan_segments(<<0xFF, _marker, length::big-16, rest::binary>>) do
    # `length` counts itself, so the payload is length - 2 bytes.
    case rest do
      <<_skip::binary-size(length - 2), tail::binary>> -> scan_segments(tail)
      _ -> :error
    end
  end

  defp scan_segments(<<0xFF>>), do: :error
  defp scan_segments(_), do: :error
end
