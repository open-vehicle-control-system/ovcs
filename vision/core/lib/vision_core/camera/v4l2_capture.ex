defmodule VisionCore.Camera.V4L2Capture do
  @moduledoc """
  What the drivers running `v4l2_capture`, `VisionCore.Camera.V4L2Pair` and
  `VisionCore.Camera.V4L2Single`, share: their settings, given as a list
  of specs (`%{key:, type:, range:, default:, description:}`), the
  program's Port, its log and metadata records, the watchdog that
  finds a program that stops delivering frames, and how a driver whose
  program exits or stalls starts it again (`VisionCore.Camera.Reopen`).
  """
  require Logger

  alias VisionCore.Camera.{LibCamera, Reopen}
  alias VisionCore.{PortProcess, Timing}

  @log_tag 2
  @metadata_tag 3
  @metadata_keys [:exposure_time_us, :analogue_gain, :red_gain, :blue_gain]
  @watchdog_interval_ms 1_000

  @doc "The command-line flag of a setting or option: `--exposure-us` for `:exposure_us`."
  @spec flag(atom()) :: String.t()
  def flag(key), do: "--" <> String.replace(Atom.to_string(key), "_", "-")

  @doc "Each setting of `specs` as a flag and its value, from `opts` or its default."
  @spec arguments([map()], keyword()) :: [String.t()]
  def arguments(specs, opts) do
    Enum.flat_map(specs, fn spec ->
      [flag(spec.key), encode(spec, Keyword.get(opts, spec.key, spec.default))]
    end)
  end

  @doc """
  The `name=value` commands that set `controls` on the program, or why
  one of them is refused by `specs`.
  """
  @spec commands([map()], keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def commands(specs, controls) do
    Enum.reduce_while(controls, {:ok, []}, fn {key, value}, {:ok, commands} ->
      case validate(specs, key, value) do
        {:ok, spec} -> {:cont, {:ok, commands ++ ["#{key}=#{encode(spec, value)}"]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate(specs, key, value) do
    case Enum.find(specs, &(&1.key == key)) do
      nil ->
        {:error, "unknown camera setting #{key}"}

      spec ->
        if valid?(spec, value),
          do: {:ok, spec},
          else: {:error, "#{key}: invalid value #{inspect(value)}"}
    end
  end

  @doc """
  `opts` without the settings `specs` refuses, each dropped with a
  warning prefixed by `who`: `v4l2_capture` exits on a setting it
  refuses, at every restart, so such a setting keeps its default.
  """
  @spec accepted([map()], keyword(), String.t()) :: keyword()
  def accepted(specs, opts, who) do
    Enum.filter(opts, fn {key, value} ->
      case Enum.find(specs, &(&1.key == key)) do
        nil ->
          true

        spec ->
          if valid?(spec, value) do
            true
          else
            Logger.warning("#{who} #{key}: invalid value #{inspect(value)}")
            false
          end
      end
    end)
  end

  @doc "The value of each setting of `specs` in `opts`, or its default."
  @spec controls([map()], keyword()) :: map()
  def controls(specs, opts) do
    Map.new(specs, fn spec ->
      {spec.key, normalise(spec, Keyword.get(opts, spec.key, spec.default))}
    end)
  end

  @doc "`controls` with `changes`, already accepted by `commands/2`, applied."
  @spec update([map()], map(), keyword()) :: map()
  def update(specs, controls, changes) do
    Enum.reduce(changes, controls, fn {key, value}, controls ->
      Map.put(controls, key, normalise(Enum.find(specs, &(&1.key == key)), value))
    end)
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

  defp normalise(%{type: :double}, value), do: value * 1.0
  defp normalise(_spec, value), do: value

  @doc """
  A log record (tag 2) as `{:log, level, message}`, a metadata record
  (tag 3) as `{:metadata, map}`, and `{:error, :malformed_record}` for
  anything else.

  The metadata record is `VisionCore.Camera.LibCamera`'s layout: a byte
  whose bit `i` is set when `values[i]` was reported, the frame start in
  kernel nanoseconds, then eight little-endian doubles. The program
  reports `values[0]`, the exposure in microseconds, and `values[1]`, the
  analogue gain, when it applies them, and `values[2]` and `values[3]`,
  the red and blue white balance gains, when they change. The map holds
  the values reported, as `:exposure_time_us` (rounded), `:analogue_gain`,
  `:red_gain` and `:blue_gain`, and the frame start as `:capture_ns`.
  """
  @spec parse_record(binary()) ::
          {:log, Logger.level(), binary()} | {:metadata, map()} | {:error, :malformed_record}
  def parse_record(<<@log_tag, level, message::binary>>), do: {:log, log_level(level), message}

  def parse_record(
        <<@metadata_tag, present, capture_ns::little-signed-64, encoded::binary-size(64)>>
      ) do
    values = for <<value::little-float-64 <- encoded>>, do: value

    reported =
      for {{key, value}, index} <- Enum.with_index(Enum.zip(@metadata_keys, values)),
          Bitwise.band(present, Bitwise.bsl(1, index)) != 0,
          into: %{},
          do: {key, metadata_value(key, value)}

    {:metadata, Map.put(reported, :capture_ns, Timing.monotonic_from_kernel(capture_ns))}
  end

  def parse_record(_other), do: {:error, :malformed_record}

  defp metadata_value(:exposure_time_us, value), do: round(value)
  defp metadata_value(_key, value), do: value

  @doc """
  What the program applies, `applied` (`nil` before any report), with
  `metadata`'s values, a record reporting some of them, and the system
  time it was received as `:received_ms`.
  """
  @spec applied(map() | nil, map()) :: map()
  def applied(applied, metadata) do
    (applied || %{})
    |> Map.merge(metadata)
    |> Map.put(:received_ms, System.system_time(:millisecond))
  end

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_), do: :error

  @doc """
  The capture program, `opts`'s `:executable` or `priv/v4l2_capture`.
  Raises, naming `who`, when it is missing.
  """
  @spec executable!(keyword(), String.t()) :: Path.t()
  def executable!(opts, who) do
    executable = Keyword.get_lazy(opts, :executable, fn -> binary_path(who) end)

    unless File.exists?(executable) do
      raise "#{who}: v4l2_capture missing at #{executable}; " <>
              "the :okdo_c100 and :arduino_ventuno_q firmware builds provide it."
    end

    executable
  end

  @doc """
  What a driver keeps of its program before it runs, from `opts`: the
  `:executable` (`executable!/2`), no `:port`, the waits it is started
  again on (`VisionCore.Camera.Reopen`), and `timeouts`'
  `:stall_timeout_ms` and `:startup_timeout_ms`. Starts the watchdog,
  which sends the calling process `:watchdog` (`watchdog/2`).
  """
  @spec closed(keyword(), keyword(), String.t()) :: map()
  def closed(opts, timeouts, who) do
    Process.send_after(self(), :watchdog, @watchdog_interval_ms)

    %{
      executable: executable!(opts, who),
      port: nil,
      failures: 0,
      reopen_delays_ms: Reopen.delays!(opts),
      started_at: now_ms(),
      last_frame_at: nil,
      stall_timeout_ms: Keyword.fetch!(timeouts, :stall_timeout_ms),
      startup_timeout_ms: Keyword.fetch!(timeouts, :startup_timeout_ms)
    }
  end

  @doc "`state` with its program running with `arguments`, no frame delivered yet."
  @spec open(map(), [String.t()]) :: map()
  def open(state, arguments) do
    port =
      Port.open({:spawn_executable, state.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: arguments
      ])

    %{state | port: port, started_at: now_ms(), last_frame_at: nil}
  end

  @doc "`state` once its program has delivered a frame."
  @spec delivered(map()) :: map()
  def delivered(state), do: Reopen.delivered(%{state | last_frame_at: now_ms()})

  @doc """
  `state` after its program exited with `status`, logged with `who`: no
  Port, and `:reopen` sent to the calling process after the next wait.
  """
  @spec exited(map(), non_neg_integer(), String.t()) :: map()
  def exited(state, status, who) do
    Logger.error(
      "#{who} v4l2_capture exited with status #{status}; " <>
        "starting it again in #{Reopen.delay_ms(state)} ms"
    )

    Reopen.closed(state)
  end

  @doc """
  The watchdog's check of `state`, which holds the fields `closed/3`
  returns, with the next check scheduled: `state` while frames come or
  the program does not run; once none came within `:startup_timeout_ms`
  of the start or within `:stall_timeout_ms` of the last frame, logged
  with `who`, `state` with its Port closed, the program killed if it
  does not exit (`VisionCore.PortProcess`), to be started again as
  after an exit.
  """
  @spec watchdog(map(), String.t()) :: map()
  def watchdog(%{port: nil} = state, _who) do
    Process.send_after(self(), :watchdog, @watchdog_interval_ms)
    state
  end

  def watchdog(state, who) do
    Process.send_after(self(), :watchdog, @watchdog_interval_ms)

    case LibCamera.stall_verdict(state, now_ms()) do
      :ok ->
        state

      verdict ->
        Logger.error(
          "#{who} v4l2_capture stopped delivering: #{inspect(verdict)}; " <>
            "starting it again in #{Reopen.delay_ms(state)} ms"
        )

        PortProcess.close(state.port)
        Reopen.closed(state)
    end
  end

  @doc """
  Sends `commands` to the program of `state`; without one they are left
  out, the settings they set being its arguments when it starts.
  """
  @spec command(map(), [String.t()]) :: :ok
  def command(%{port: nil}, _commands), do: :ok

  def command(%{port: port}, commands) do
    Enum.each(commands, &Port.command(port, &1))
  rescue
    # The program exited, its exit status not handled yet.
    ArgumentError -> :ok
  end

  @doc "The monotonic time in milliseconds, as `:last_frame_at` holds it."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  defp binary_path(who) do
    case :code.priv_dir(:vision_core) do
      {:error, :bad_name} ->
        raise "#{who}: :vision_core app not loaded; cannot locate v4l2_capture"

      priv_directory ->
        Path.join([List.to_string(priv_directory), "v4l2_capture"])
    end
  end
end
