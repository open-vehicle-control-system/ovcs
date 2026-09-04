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

  ## Opts

    * `:label` (required) — `"left"` / `"right"`, as for every driver.
    * `:topic` (required) — the ROS topic to consume, e.g.
      `"/stereo/left/image_raw/compressed"`.

  `:width`, `:height` and `:fps` are accepted and ignored: the
  publisher decides the format, and quietly resizing here would hide a
  simulator configured differently from the vehicle rather than
  surface it.

  ## Compressed, not raw

  The topic carries JPEG, and that is not incidental. A 480x270 rgb8
  frame is 389 KB; at 30 Hz that is 11.6 MB/s, and measured over
  Zenoh a subscriber that cannot drain it that fast receives **one
  frame every fifteen seconds** — the transport drops what the link
  will not carry, and the failure looks like a dead topic rather than
  a saturated one. The same stream as JPEG is about 6.5 KB a frame.
  Compression belongs upstream of the fabric, which is also what the
  real vehicle does.

  ## Time

  Frames are stamped with local `System.monotonic_time/1` on arrival,
  not with the stamp they carry. `Frame.capture_ns` means Erlang
  monotonic time everywhere in this bridge — `RosBridge.Timing` is
  built on that and converts foreign clocks at the driver boundary —
  and a simulator's clock starts at zero and advances with physics, so
  passing it through would project to a wall-clock time nearly two
  decades wrong.

  That used to mean outgoing headers carried arrival time rather than
  simulation time and so did not line up with `/clock`. It no longer
  does: `RosBridge.Clock` keeps a monotonic-to-simulator offset, and
  `RosBridge.Timing` projects through it, so arrival time lands on the
  simulator's timescale without this driver having to pass a foreign
  clock through. Frames stay on Erlang monotonic time here, which is
  the invariant that made the conversion possible in one place.

  Pairing was never affected either way: both sides are published
  together and land within a millisecond of each other, far inside
  `:pair_tolerance_ms`.
  """
  @behaviour RosBridge.Camera

  use GenServer

  require Logger

  alias Ros2.SensorMsgs.Msg.CompressedImage
  alias RosBridge.Camera.Frame

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    GenServer.start_link(__MODULE__, opts, name: name_for(label))
  end

  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @impl RosBridge.Camera
  def register_listener(server, listener) do
    GenServer.cast(server, {:register_listener, listener})
  end

  @impl RosBridge.Camera
  def enable(_server), do: :ok

  @impl true
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    topic = Keyword.fetch!(opts, :topic)

    # Subscribing from `init/1` is safe: ZenohClient records the
    # subscription and declares it on the next successful connect, so
    # a camera that starts before the session is up still works.
    :ok = RosBridge.ZenohClient.subscribe(topic, CompressedImage)

    Logger.info("#{__MODULE__}[#{label}] consuming #{topic}")

    {:ok, %{label: label, topic: topic, listeners: [], frames: 0}}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl true
  def handle_info({:ros_message, {_key_expr, %CompressedImage{} = image}}, state) do
    case decode_dimensions(image.data) do
      {:ok, width, height} ->
        frame = %Frame{
          label: state.label,
          width: width,
          height: height,
          capture_ns: System.monotonic_time(:nanosecond),
          jpeg: image.data
        }

        Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))
        {:noreply, %{state | frames: state.frames + 1}}

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

  # Padding between segments is legal; skip a stray fill byte.
  defp scan_segments(<<0xFF>>), do: :error
  defp scan_segments(_), do: :error
end
