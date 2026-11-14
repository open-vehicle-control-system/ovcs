defmodule VisionCore.Camera.V4L2Pair do
  @moduledoc """
  `VisionCore.Camera` driver for a stereo pair of IMX708 sensors
  (Raspberry Pi Camera Module 3) captured over raw V4L2 by one
  `v4l2_capture` program, by default on the OKdo Nano C100's two CSI
  ports. The program locks the right sensor's frame starts to the left
  one's and writes frame pairs, so both sides come from one Port.

  The `"left"` instance opens the Port and publishes left frames. It
  hands each right frame to the `"right"` instance, which opens nothing
  and publishes what it receives. When the program exits or stops
  delivering, the left instance stays up and starts it again after a
  wait that grows with each failure in a row
  (`VisionCore.Camera.Reopen`, `:reopen_delays_ms`), with the settings in
  force; a program that stalled is closed first, and killed if it does
  not exit. Both instances keep answering meanwhile.

  Frames are 8-bit grey (`%Frame{grey: ...}`): the program averages each
  2x2 Bayer cell, so the output is half the sensor mode in each axis.

  ## Framing protocol

  Records on the Port's stdout are `{:packet, 4}`:

      uint8   tag                 # 4 = PAIR
      uint16  width   LE
      uint16  height  LE
      int64   left_ns LE          # frame starts, kernel CLOCK_MONOTONIC
      int64   right_ns LE
      bytes   left                # width * height
      bytes   right               # width * height

  a log line, as `VisionCore.Camera.LibCamera` reads it:

      uint8   tag                 # 2 = LOG
      uint8   level               # 0 info, 1 warning, 2 error
      bytes   message

  or the exposure and gain the program just applied, in
  `VisionCore.Camera.LibCamera`'s metadata record (tag 3): the present
  bits are 0 and 1, `values[0]` is the exposure in microseconds,
  `values[1]` the analogue gain, and the time is the left frame's start
  (0 before the first frame). `live/1` returns the latest.

  Records the other way, on the program's stdin, change a setting each:
  `name=value`, as `control_commands/1` builds them. Closing stdin stops
  the program.

  ## Settings

  The sensors are raw, with no ISP: the program converts their Bayer
  samples to grey and runs the exposure itself. Its settings apply to
  both sensors, so the `:stereo` component takes them once, beside
  `:width` (`pair_options/0`). They can change while running through
  `set_controls/2` on either camera, so they are also the stereo unit's
  `<prefix>.cameras` parameters. `control_specs/0` lists them with their
  defaults. No autofocus runs: the program holds both lenses at the
  `focus` setting.

  Auto exposure keeps the exposure and gain within `max_exposure_us`
  and `max_gain` at every step, and brings them within lowered caps as
  they are set.

  ## Opts

  The stereo unit gives each instance these; the left one uses all of
  them, the right one its `:label` and `:frame_id`.

    * `:label` — `"left"` or `"right"`.
    * `:frame_id` — the optical frame each of this side's frames carries.
    * `:width`, `:height`, `:fps` — the output size and frame rate.
    * `:left`, `:right` — each side's options:
      * `:video`, `:sensor` — the V4L2 names
        (`/sys/class/video4linux/*/name`) of the side's capture node and
        sensor subdevice; the C100's CSI ports by default.
      * `:csiphy` — on a CAMSS board such as the Arduino VENTUNO Q, the
        CSI PHY the side's sensor is wired to: `VisionCore.Camera.Camss`
        routes it, at twice `:width` × `:height`, and names its nodes, in
        place of `:video` and `:sensor`. The media device and the sensors
        register some seconds after boot: while a PHY has no sensor, the
        cameras start without the program and route again on the waits
        of `:reopen_delays_ms`, each failure logged.
    * `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`) — the wait
      before the program is started again, the last one repeated.
    * any setting of `control_specs/0`, by its key.
    * `:media_runner` — runs `media-ctl` for the routing, as
      `VisionCore.Camera.Camss.route/2`'s `:runner` (tests).
    * `:executable` — the capture program (default `priv/v4l2_capture`).
  """
  use GenServer
  require Logger

  @behaviour VisionCore.Camera

  alias VisionCore.Camera.{Camss, Frame, Reopen}
  alias VisionCore.Camera.V4L2Capture
  alias VisionCore.{Outputs, Timing}

  @pair_tag 4
  @stall_timeout_ms 2_000
  @startup_timeout_ms 15_000
  # The OKdo Nano C100's two CSI ports, a Camera Module 3 on each.
  @default_nodes [
    left: [video: "54080000.vi-output-0", sensor: "imx708 5-001a"],
    right: [video: "54080000.vi-output-4", sensor: "imx708 6-001a"]
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :label)))
  end

  @doc "The registered name of the driver for `label`."
  @impl VisionCore.Camera
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @doc "Whether the capture program runs: `false` while the driver waits to start it again."
  @spec running?(GenServer.server()) :: boolean()
  defdelegate running?(server), to: VisionCore.Camera.Reopen

  @settings [
    %{
      key: :rotation,
      type: :integer,
      range: {0, 180},
      default: 0,
      description: "Image rotation in degrees, 0 or 180 for sensors mounted upside down"
    },
    %{
      key: :auto_exposure,
      type: :bool,
      default: true,
      description: "Automatic exposure; off, exposure_us and analogue_gain apply as set"
    },
    %{
      key: :exposure_us,
      type: :integer,
      range: {100, 1_000_000},
      default: 8_000,
      description: "Exposure time in microseconds: fixed, or where auto exposure starts"
    },
    %{
      key: :analogue_gain,
      type: :double,
      range: {1, 16},
      default: 2.0,
      description: "Analogue gain: fixed, or where auto exposure starts"
    },
    %{
      key: :target_brightness,
      type: :double,
      range: {1, 254},
      default: 110.0,
      description: "Mean grey auto exposure steers the image to, 0 to 255"
    },
    %{
      key: :max_exposure_us,
      type: :integer,
      range: {100, 1_000_000},
      default: 20_000,
      description:
        "Longest exposure auto exposure uses before raising the gain, against motion blur"
    },
    %{
      key: :max_gain,
      type: :double,
      range: {1, 16},
      default: 16.0,
      description: "Highest analogue gain auto exposure uses"
    },
    %{
      key: :black_level,
      type: :integer,
      range: {0, 1022},
      default: 64,
      description: "Raw 10-bit sample value of black"
    },
    %{
      key: :gamma,
      type: :double,
      range: {0.5, 4},
      default: 2.2,
      description: "Gamma the grey image is encoded with"
    },
    %{
      key: :focus,
      type: :integer,
      range: {0, 1023},
      default: 428,
      description: "Both lens actuators' position, 512 unpowered"
    }
  ]

  @doc """
  The capture settings, applied to both sensors: `%{key:, type:, range:,
  default:, description:}`.
  """
  @impl VisionCore.Camera
  def control_specs, do: @settings

  @doc """
  The `:stereo` component's options for the pair, the settings of
  `control_specs/0`, `:executable` and `:reopen_delays_ms`, and for each
  side, its nodes or CSI PHY.
  """
  @impl VisionCore.Camera
  def pair_options,
    do: %{
      pair: [:executable, :reopen_delays_ms | Enum.map(@settings, & &1.key)],
      side: [:csiphy, :video, :sensor]
    }

  @doc """
  `opts` with the nodes of each side given a `:csiphy` named after
  routing the sensor on it; the routing's error otherwise.
  """
  @spec routed(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def routed(opts) do
    route_opts =
      [
        width: 2 * Keyword.fetch!(opts, :width),
        height: 2 * Keyword.fetch!(opts, :height),
        await: 0
      ] ++
        if runner = opts[:media_runner], do: [runner: runner], else: []

    Enum.reduce_while([:left, :right], {:ok, opts}, fn side, {:ok, opts} ->
      side_opts = Keyword.get(opts, side, [])

      case Keyword.fetch(side_opts, :csiphy) do
        :error ->
          {:cont, {:ok, opts}}

        {:ok, csiphy} ->
          case Camss.route(csiphy, route_opts) do
            {:ok, route} ->
              nodes = [video: "msm_vfe#{csiphy}_video0", sensor: route.sensor]
              {:cont, {:ok, Keyword.put(opts, side, Keyword.merge(side_opts, nodes))}}

            {:error, message} ->
              {:halt, {:error, "#{side} camera: #{message}"}}
          end
      end
    end)
  end

  @doc false
  def port_arguments(opts) do
    size =
      for key <- [:width, :height, :fps],
          do: ["--#{key}", Integer.to_string(Keyword.fetch!(opts, key))]

    nodes =
      for {side, defaults} <- @default_nodes, {key, default} <- defaults do
        ["--#{side}-#{key}", opts |> Keyword.get(side, []) |> Keyword.get(key, default)]
      end

    List.flatten(size ++ nodes) ++ V4L2Capture.arguments(@settings, opts)
  end

  @doc """
  The `name=value` commands that set `controls` on the capture program,
  or why one of them is refused.
  """
  @spec control_commands(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def control_commands(controls), do: V4L2Capture.commands(@settings, controls)

  @impl VisionCore.Camera
  def shared_controls?, do: true

  @impl VisionCore.Camera
  def set_controls(server, controls), do: GenServer.call(server, {:set_controls, controls})

  @impl VisionCore.Camera
  def controls(server), do: GenServer.call(server, :controls)

  @doc """
  The exposure and gain the capture program applies, as
  `VisionCore.Camera.LibCamera.live/1` reports them: `:exposure_time_us`,
  `:analogue_gain`, `:capture_ns` and `:received_ms` (system time). `nil`
  before the first report. The right camera asks the left.
  """
  @spec live(GenServer.server()) :: map() | nil
  @impl VisionCore.Camera
  def live(server), do: GenServer.call(server, :live)

  @doc false
  def parse_record(
        <<@pair_tag, width::little-16, height::little-16, left_ns::little-signed-64,
          right_ns::little-signed-64, pixels::binary>>
      )
      when byte_size(pixels) == 2 * width * height do
    <<left::binary-size(^width * ^height), right::binary>> = pixels

    {:pair, frame("left", width, height, left_ns, left),
     frame("right", width, height, right_ns, right)}
  end

  def parse_record(record), do: V4L2Capture.parse_record(record)

  defp frame(label, width, height, kernel_ns, grey) do
    %Frame{
      label: label,
      width: width,
      height: height,
      capture_ns: Timing.monotonic_from_kernel(kernel_ns),
      grey: grey
    }
  end

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    opts = V4L2Capture.accepted(@settings, opts, "#{__MODULE__}[#{label}]")
    controls = V4L2Capture.controls(@settings, opts)

    state = %{
      label: label,
      frame_id: Keyword.get(opts, :frame_id),
      output: {:camera_frame, name_for(label)},
      port: nil,
      controls: controls,
      applied: nil
    }

    if label == "left" do
      timeouts = [stall_timeout_ms: @stall_timeout_ms, startup_timeout_ms: @startup_timeout_ms]
      state = Map.merge(state, V4L2Capture.closed(opts, timeouts, "#{__MODULE__}"))
      {:ok, Map.put(state, :opts, opts), {:continue, :open}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:open, state), do: {:noreply, open(state)}

  # Starts the program with the settings in force; a PHY without its sensor is tried again later.
  defp open(state) do
    case routed(Keyword.merge(state.opts, Map.to_list(state.controls))) do
      {:ok, opts} ->
        V4L2Capture.open(state, port_arguments(opts))

      {:error, message} ->
        Logger.error("#{__MODULE__}: #{message}; trying again in #{Reopen.delay_ms(state)} ms")
        Reopen.closed(state)
    end
  end

  @impl GenServer
  def handle_call(request, _from, %{label: "right"} = state) do
    # The settings live with the left camera, which runs the program.
    {:reply, GenServer.call(name_for("left"), request), state}
  end

  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}
  def handle_call(:controls, _from, state), do: {:reply, state.controls, state}
  def handle_call(:live, _from, state), do: {:reply, state.applied, state}

  def handle_call({:set_controls, controls}, _from, state) do
    case control_commands(controls) do
      {:ok, commands} ->
        V4L2Capture.command(state, commands)
        updated = V4L2Capture.update(@settings, state.controls, controls)

        {:reply, {:ok, updated}, %{state | controls: updated}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_cast({:pair_frame, %Frame{} = frame}, state) do
    publish_frame(state, frame)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:pair, left, right} ->
        publish_frame(state, left)
        GenServer.cast(name_for("right"), {:pair_frame, right})

        {:noreply, V4L2Capture.delivered(%{state | applied: refreshed(state.applied)})}

      {:metadata, metadata} ->
        applied = Map.put(metadata, :received_ms, System.system_time(:millisecond))
        {:noreply, %{state | applied: applied}}

      {:log, level, message} ->
        Logger.log(level, "#{__MODULE__} v4l2_capture: #{message}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("#{__MODULE__} dropping malformed record: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, V4L2Capture.exited(%{state | applied: nil}, status, "#{__MODULE__}")}
  end

  def handle_info(:reopen, %{label: "left", port: nil} = state), do: {:noreply, open(state)}

  def handle_info(:watchdog, state),
    do: {:noreply, V4L2Capture.watchdog(state, "#{__MODULE__}")}

  def handle_info(_message, state), do: {:noreply, state}

  # The program reports only when the exposure changes; frames keep it fresh.
  defp refreshed(nil), do: nil
  defp refreshed(applied), do: %{applied | received_ms: System.system_time(:millisecond)}

  defp publish_frame(state, frame),
    do: Outputs.publish(state.output, {:camera_frame, %{frame | frame_id: state.frame_id}})
end
