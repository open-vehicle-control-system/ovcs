defmodule VisionCore.Camera.V4L2 do
  @moduledoc """
  `VisionCore.Camera` driver for a stereo pair captured over raw V4L2 by
  one `v4l2_capture` program, such as the OKdo Nano C100's two CSI
  cameras. The program locks the right sensor's frame starts to the left
  one's and writes frame pairs, so both sides come from one Port.

  The `"left"` instance opens the Port and fans out left frames. It hands
  each right frame to the `"right"` instance, which opens nothing and fans
  out what it receives. When the program exits or stops delivering, the
  left instance stops; the stereo unit's `:rest_for_one` supervision then
  restarts the right one after it.

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
  both sensors, are given in the left camera's opts, and can change
  while running through `set_controls/2` on either camera, so they are
  also the stereo unit's `<prefix>.cameras` parameters. `control_specs/0`
  lists them with their defaults; the lens, which no autofocus drives
  here, stays at its rest position.

  ## Opts

    * `:label` — `"left"` or `"right"`.
    * `:width`, `:height`, `:fps` — the output size and frame rate (left).
    * any setting of `control_specs/0`, by its key (left).
    * `:executable` — the capture program (default `priv/v4l2_capture`).
  """
  use GenServer
  require Logger

  @behaviour VisionCore.Camera

  alias VisionCore.Camera.{Frame, LibCamera}
  alias VisionCore.Timing

  @pair_tag 4
  @log_tag 2
  @metadata_tag 3
  @watchdog_interval_ms 1_000
  @stall_timeout_ms 2_000
  @startup_timeout_ms 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.fetch!(opts, :label)))
  end

  @doc "The registered name of the driver for `label`."
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @impl VisionCore.Camera
  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

  @impl VisionCore.Camera
  def enable(_server), do: :ok

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
      description:
        "Both lens actuators' position, 512 unpowered; 428 focuses the Camera Module 3 Wide at about 1.5 to 2 m"
    }
  ]

  @doc """
  The capture settings, applied to both sensors: `%{key:, type:, range:,
  default:, description:}`.
  """
  def control_specs, do: @settings

  @doc false
  def port_args(opts) do
    size =
      for key <- [:width, :height, :fps],
          do: ["--#{key}", Integer.to_string(Keyword.fetch!(opts, key))]

    settings =
      for spec <- @settings do
        flag = "--" <> String.replace(Atom.to_string(spec.key), "_", "-")
        [flag, encode(spec, Keyword.get(opts, spec.key, spec.default))]
      end

    List.flatten(size ++ settings)
  end

  @doc """
  The `name=value` commands that set `controls` on the capture program,
  or why one of them is refused.
  """
  @spec control_commands(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def control_commands(controls) do
    Enum.reduce_while(controls, {:ok, []}, fn {key, value}, {:ok, commands} ->
      case validate(key, value) do
        {:ok, spec} -> {:cont, {:ok, commands ++ ["#{key}=#{encode(spec, value)}"]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate(key, value) do
    case Enum.find(@settings, &(&1.key == key)) do
      nil ->
        {:error, "unknown camera setting #{key}"}

      spec ->
        if valid?(spec, value),
          do: {:ok, spec},
          else: {:error, "#{key}: invalid value #{inspect(value)}"}
    end
  end

  defp valid?(%{key: :rotation}, value), do: value in [0, 180]
  defp valid?(%{type: :bool}, value), do: is_boolean(value)

  defp valid?(%{type: :integer, range: {min, max}}, value),
    do: is_integer(value) and value in min..max

  defp valid?(%{type: :double, range: {min, max}}, value),
    do: is_number(value) and value >= min and value <= max

  defp encode(%{type: :bool}, value), do: to_string(value == true)
  defp encode(%{type: :integer}, value), do: Integer.to_string(round(value))
  defp encode(%{type: :double}, value), do: Float.to_string(value * 1.0)

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

  def parse_record(<<@log_tag, level, message::binary>>), do: {:log, log_level(level), message}
  def parse_record(<<@metadata_tag, _rest::binary>> = record), do: LibCamera.parse_record(record)
  def parse_record(_other), do: {:error, :malformed_record}

  defp frame(label, width, height, kernel_ns, grey) do
    %Frame{
      label: label,
      width: width,
      height: height,
      capture_ns: Timing.monotonic_from_kernel(kernel_ns),
      grey: grey
    }
  end

  defp normalise(%{type: :double}, value), do: value * 1.0
  defp normalise(_spec, value), do: value

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_), do: :error

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)

    controls =
      Map.new(@settings, fn spec ->
        {spec.key, normalise(spec, Keyword.get(opts, spec.key, spec.default))}
      end)

    state = %{label: label, listeners: [], port: nil, controls: controls, applied: nil}

    if label == "left" do
      {:ok, open_port(state, opts)}
    else
      {:ok, state}
    end
  end

  defp open_port(state, opts) do
    executable = Keyword.get_lazy(opts, :executable, &binary_path/0)

    unless File.exists?(executable) do
      raise "#{__MODULE__}: v4l2_capture missing at #{executable}; " <>
              "the :okdo_c100 firmware build provides it."
    end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: port_args(opts)
      ])

    Process.send_after(self(), :watchdog, @watchdog_interval_ms)

    Map.merge(state, %{
      port: port,
      started_at: now_ms(),
      last_frame_at: nil,
      stall_timeout_ms: @stall_timeout_ms,
      startup_timeout_ms: @startup_timeout_ms
    })
  end

  @impl GenServer
  def handle_call(request, _from, %{port: nil} = state) do
    # The settings live with the left camera, which runs the program.
    {:reply, GenServer.call(name_for("left"), request), state}
  end

  def handle_call(:controls, _from, state), do: {:reply, state.controls, state}
  def handle_call(:live, _from, state), do: {:reply, state.applied, state}

  def handle_call({:set_controls, controls}, _from, state) do
    case control_commands(controls) do
      {:ok, commands} ->
        Enum.each(commands, &Port.command(state.port, &1))

        updated =
          Enum.reduce(controls, state.controls, fn {key, value}, acc ->
            Map.put(acc, key, normalise(Enum.find(@settings, &(&1.key == key)), value))
          end)

        {:reply, {:ok, updated}, %{state | controls: updated}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state),
    do: {:noreply, %{state | listeners: state.listeners ++ [listener]}}

  def handle_cast({:pair_frame, %Frame{} = frame}, state) do
    fan_out(state, frame)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case parse_record(packet) do
      {:pair, left, right} ->
        fan_out(state, left)
        GenServer.cast(name_for("right"), {:pair_frame, right})
        {:noreply, %{state | last_frame_at: now_ms(), applied: refreshed(state.applied)}}

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
    Logger.error("#{__MODULE__} v4l2_capture exited with status #{status}")
    {:stop, {:v4l2_capture_exit, status}, state}
  end

  def handle_info(:watchdog, state) do
    case LibCamera.stall_verdict(state, now_ms()) do
      :ok ->
        Process.send_after(self(), :watchdog, @watchdog_interval_ms)
        {:noreply, state}

      verdict ->
        Logger.error("#{__MODULE__} v4l2_capture stopped delivering: #{inspect(verdict)}")
        {:stop, {:camera_stall, verdict}, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The program reports only when the exposure changes; frames keep it fresh.
  defp refreshed(nil), do: nil
  defp refreshed(applied), do: %{applied | received_ms: System.system_time(:millisecond)}

  defp fan_out(state, frame),
    do: Enum.each(state.listeners, &GenServer.cast(&1, {:camera_frame, frame}))

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp binary_path do
    case :code.priv_dir(:vision_core) do
      {:error, :bad_name} ->
        raise "#{__MODULE__}: :vision_core app not loaded; cannot locate v4l2_capture"

      priv_directory ->
        Path.join([List.to_string(priv_directory), "v4l2_capture"])
    end
  end
end
