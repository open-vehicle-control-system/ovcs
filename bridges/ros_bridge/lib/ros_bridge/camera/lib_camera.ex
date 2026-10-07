defmodule RosBridge.Camera.LibCamera do
  @moduledoc """
  Target-side `RosBridge.Camera` implementation. Spawns the
  `camera_capture` native binary (one Port per camera), parses its
  length-prefixed framing protocol, and fans frames out to
  registered listeners.

  The native binary lives in `bridges/ros_bridge/priv/` (built via
  `:elixir_make` from `bridges/ros_bridge/c_src/camera_capture/`)
  and owns libcamera + the Pi 5 ISP path. See the c_src README
  there for the wire protocol.

  ## Framing protocol (matches `c_src/camera_capture/framing.h`)

  Each record on the port's stdout is a 4-byte big-endian length
  prefix (set via `Port.open` `{:packet, 4}`), followed by:

      uint8   tag                 # 1 = FRAME
      uint16  width   LE
      uint16  height  LE
      int64   capture_ns LE
      uint32  jpeg_len  LE
      bytes   jpeg

  or a log line from the binary, written to the logger under this
  camera's label (the Port does not capture its stderr):

      uint8   tag                 # 2 = LOG
      uint8   level               # 0 info, 1 warning, 2 error
      bytes   message

  Records the other way, on the binary's stdin, are `key=value`
  runtime controls (see "Runtime controls").

  The Port supervises the binary: closing stdin (which happens
  when this GenServer dies) tells the binary to exit cleanly.

  ## Sync

  The cameras of a stereo pair run on their own clocks, so their frames
  are taken up to half a frame period apart, a different offset at each
  start. While the vehicle turns, that shifts one image against the
  other and corrupts the disparity. `:sync` (`:server` on one camera,
  `:client` on the other) enables libcamera's software camera sync on
  the Pi 5: the client aligns its frame starts to the server's. It needs
  the sensor's tuning file to carry `rpi.sync` and the two processes to
  reach each other over UDP multicast. Absent, the camera runs free.

  ## Exposure

  `:exposure_mode` (`:normal`, `:short`, `:long`) picks the
  auto-exposure mode of the sensor's tuning file. On the Camera
  Module 3, `:normal` keeps the shutter open up to 30 ms before raising
  the gain, which smears a moving image; `:short` caps it at 10 ms
  before raising the gain, trading blur for noise. Absent, libcamera
  uses `:normal`.

  ## Focus

  `:lens_position` fixes the focus of a sensor that has a motorised
  lens (Camera Module 3), in dioptres: 1.0 is focused at 1 m, 0 at
  infinity. A stereo calibration holds only while the lens stays put,
  and the two modules of a pair may need different positions to be
  equally sharp. Absent, the lens is left where libcamera puts it.

  ## Sensor mode

  `:sensor_mode` (`{width, height}`, 10-bit) picks the sensor mode
  instead of letting libcamera choose one from the output size. For a
  small output libcamera picks the fastest mode, which on the Camera
  Module 3 (IMX708) is 1536x864: a binned crop of the sensor's centre,
  two thirds of its width, so about 43° of horizontal field of view.
  `{2304, 1296}` bins the whole sensor (about 66°, up to 56 fps). A
  stereo calibration holds for one sensor mode only.

  ## Runtime controls

  `set_controls/2` changes exposure, gain, focus and image processing
  while capturing; the capture program applies them from the next frame
  on. Accepted keys:

    * `:exposure_mode` — `:normal`, `:short`, `:long`
    * `:exposure_time_us` — a fixed shutter time, 0 for automatic
    * `:analogue_gain` — a fixed gain, 0 for automatic
    * `:lens_position` — focus in dioptres (manual focus)
    * `:brightness` (-1..1), `:contrast` (0..32), `:sharpness` (0..16)
    * `:noise_reduction` — `:off`, `:fast`, `:high_quality`, `:minimal`

  The sync role, sensor mode, resolution and frame rate are fixed at
  start.

  ## Stall watchdog

  A capture can stop delivering frames without the binary exiting:
  libcamera keeps the process alive, sleeping on its request queue,
  and nothing on this side would ever notice — the port stays open,
  the supervisor sees a healthy child, and the fabric simply carries
  no more images. Both cameras of a stereo pair have been seen doing
  exactly that a few seconds after boot, until the drivers were
  restarted by hand.

  So the driver watches its own frame flow. Once frames have started,
  `:stall_timeout_ms` (default 2000 ms — sixty frame periods at 30 fps)
  of silence is a stall; before the first frame, `:startup_timeout_ms`
  (default 15000 ms, libcamera's pipeline set-up on a Pi 5 can take a
  few seconds) is the most a camera gets to produce one. Either way the
  driver logs the reason and stops, and the stereo supervisor's
  `:rest_for_one` restarts it together with everything downstream, which
  re-runs the listener registrations. The binary is relaunched by the
  restart, and with it libcamera's pipeline.
  """
  @behaviour RosBridge.Camera

  use GenServer
  require Logger

  alias RosBridge.Camera.Frame

  @frame_tag 1
  @log_tag 2
  @watchdog_interval_ms 1_000
  @default_stall_timeout_ms 2_000
  @default_startup_timeout_ms 15_000

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    name = name_for(label)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @doc false
  def sync_args(nil), do: []
  def sync_args(role) when role in [:server, :client], do: ["--sync", Atom.to_string(role)]

  @doc false
  def exposure_mode_args(nil), do: []

  def exposure_mode_args(mode) when mode in [:normal, :short, :long],
    do: ["--exposure-mode", Atom.to_string(mode)]

  @doc false
  def sensor_mode_args(nil), do: []

  def sensor_mode_args({width, height}) when is_integer(width) and is_integer(height),
    do: ["--sensor-mode", "#{width}x#{height}"]

  @doc false
  def lens_position_args(nil), do: []
  def lens_position_args(dioptres), do: ["--lens-position", Float.to_string(dioptres * 1.0)]

  @impl true
  def init(opts) do
    label = Keyword.fetch!(opts, :label)
    camera_id = Keyword.fetch!(opts, :camera_id)
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)
    rotation = Keyword.get(opts, :rotation, 0)
    sync = Keyword.get(opts, :sync)
    exposure_mode = Keyword.get(opts, :exposure_mode)
    lens_position = Keyword.get(opts, :lens_position)
    sensor_mode = Keyword.get(opts, :sensor_mode)

    executable = binary_path()

    unless File.exists?(executable) do
      raise "#{__MODULE__}[#{label}]: native binary missing at #{executable}; " <>
              "build with `mix compile` on the :rpi5 target (elixir_make)."
    end

    args =
      [
        "--camera",
        Integer.to_string(camera_id),
        "--width",
        Integer.to_string(width),
        "--height",
        Integer.to_string(height),
        "--fps",
        Integer.to_string(fps),
        "--rotation",
        Integer.to_string(rotation)
      ] ++
        sync_args(sync) ++
        exposure_mode_args(exposure_mode) ++
        lens_position_args(lens_position) ++ sensor_mode_args(sensor_mode)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: args
      ])

    Logger.info(
      "#{__MODULE__}[#{label}] camera #{camera_id} @ #{width}×#{height}/#{fps}fps via #{executable}"
    )

    Process.send_after(self(), :watchdog, @watchdog_interval_ms)

    {:ok,
     %{
       label: label,
       camera_id: camera_id,
       port: port,
       listeners: [],
       controls: initial_controls(exposure_mode, lens_position),
       started_at: now_ms(),
       last_frame_at: nil,
       stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @default_stall_timeout_ms),
       startup_timeout_ms: Keyword.get(opts, :startup_timeout_ms, @default_startup_timeout_ms)
     }}
  end

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:ok, %Frame{} = frame} ->
        frame = %{frame | label: state.label}
        Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))
        {:noreply, %{state | last_frame_at: now_ms()}}

      {:log, level, message} ->
        Logger.log(level, "#{__MODULE__}[#{state.label}] camera_capture: #{message}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}[#{state.label}] dropping malformed record: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("#{__MODULE__}[#{state.label}] camera_capture exited with status #{status}")

    {:stop, {:camera_capture_exit, status}, state}
  end

  def handle_info(:watchdog, state) do
    case stall_verdict(state, now_ms()) do
      :ok ->
        Process.send_after(self(), :watchdog, @watchdog_interval_ms)
        {:noreply, state}

      {:stalled, silent_ms} ->
        Logger.error(
          "#{__MODULE__}[#{state.label}] no frame for #{silent_ms} ms; restarting camera_capture"
        )

        {:stop, {:camera_stall, silent_ms}, state}

      {:no_first_frame, waited_ms} ->
        Logger.error(
          "#{__MODULE__}[#{state.label}] no frame #{waited_ms} ms after start; restarting camera_capture"
        )

        {:stop, {:camera_stall, :no_first_frame}, state}
    end
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl RosBridge.Camera
  def register_listener(server, listener) do
    GenServer.cast(server, {:register_listener, listener})
  end

  @impl RosBridge.Camera
  def enable(_server), do: :ok

  @impl RosBridge.Camera
  def set_controls(server, controls), do: GenServer.call(server, {:set_controls, controls})

  @impl RosBridge.Camera
  def controls(server), do: GenServer.call(server, :controls)

  @impl true
  def handle_call({:set_controls, controls}, _from, state) do
    case control_commands(controls) do
      {:ok, commands} ->
        Enum.each(commands, &Port.command(state.port, &1))
        controls = Map.merge(state.controls, Map.new(controls))
        {:reply, {:ok, controls}, %{state | controls: controls}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:controls, _from, state), do: {:reply, state.controls, state}

  @modes %{
    exposure_mode: [:normal, :short, :long],
    noise_reduction: [:off, :fast, :high_quality, :minimal]
  }
  @ranges %{
    exposure_time_us: {0, 1_000_000},
    analogue_gain: {0, 16},
    lens_position: {0, 15},
    brightness: {-1, 1},
    contrast: {0, 32},
    sharpness: {0, 16}
  }

  @doc """
  The capture program's `key=value` commands for `controls`, or the
  first one that is not accepted. Pure.
  """
  def control_commands(controls) do
    Enum.reduce_while(controls, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case control_command(key, value) do
        {:ok, command} -> {:cont, {:ok, acc ++ [command]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp control_command(key, value) when is_map_key(@modes, key) do
    if value in @modes[key],
      do: {:ok, "#{key}=#{value}"},
      else: {:error, "#{key} must be one of #{inspect(@modes[key])}, got #{inspect(value)}"}
  end

  defp control_command(key, value) when is_map_key(@ranges, key) and is_number(value) do
    {low, high} = @ranges[key]

    if value >= low and value <= high,
      do: {:ok, "#{key}=#{value}"},
      else: {:error, "#{key} must be within #{low}..#{high}, got #{value}"}
  end

  defp control_command(key, value) when is_map_key(@ranges, key),
    do: {:error, "#{key} must be a number, got #{inspect(value)}"}

  defp control_command(key, _value), do: {:error, "unknown camera control #{inspect(key)}"}

  defp initial_controls(exposure_mode, lens_position) do
    %{exposure_mode: exposure_mode || :normal, lens_position: lens_position}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  The watchdog's decision for a driver state at `now_ms`: `:ok`,
  `{:stalled, silent_ms}` once frames have flowed and then stopped for
  longer than `:stall_timeout_ms`, or `{:no_first_frame, waited_ms}`
  when nothing has arrived `:startup_timeout_ms` after start. Pure, so
  the two timeouts can be checked without a camera.
  """
  def stall_verdict(%{last_frame_at: nil} = state, now_ms) do
    waited = now_ms - state.started_at
    if waited > state.startup_timeout_ms, do: {:no_first_frame, waited}, else: :ok
  end

  def stall_verdict(state, now_ms) do
    silent = now_ms - state.last_frame_at
    if silent > state.stall_timeout_ms, do: {:stalled, silent}, else: :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  def parse_record(<<
        @frame_tag,
        width::little-unsigned-integer-size(16),
        height::little-unsigned-integer-size(16),
        capture_ns::little-signed-integer-size(64),
        jpeg_len::little-unsigned-integer-size(32),
        jpeg::binary-size(jpeg_len)
      >>) do
    {:ok,
     %Frame{
       label: nil,
       width: width,
       height: height,
       # libcamera's SensorTimestamp (and the helper's steady_clock
       # fallback) are kernel CLOCK_MONOTONIC; Frame.capture_ns is
       # always Erlang monotonic time.
       capture_ns: RosBridge.Timing.from_kernel_monotonic(capture_ns),
       jpeg: jpeg
     }}
  end

  def parse_record(<<@log_tag, level, message::binary>>),
    do: {:log, log_level(level), message}

  def parse_record(_other), do: {:error, :malformed_record}

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_), do: :error

  # `:code.priv_dir/1` resolves to the consumer's priv (here:
  # ros_bridge's), where elixir_make drops the binary. We keep the
  # native binary in ros_bridge/priv because that's where the
  # build infrastructure already lives — ovcs_drivers stays
  # pure-Elixir.
  defp binary_path do
    case :code.priv_dir(:ros_bridge) do
      {:error, :bad_name} ->
        raise "#{__MODULE__}: :ros_bridge app not loaded; cannot locate camera_capture binary"

      dir ->
        Path.join([List.to_string(dir), "camera_capture"])
    end
  end
end
