defmodule VisionCore.Camera.V4L2.Capture do
  @moduledoc """
  What the drivers running `v4l2_capture`, `VisionCore.Camera.V4L2` and
  `VisionCore.Camera.V4L2Single`, share: their settings, given as a list
  of specs (`%{key:, type:, range:, default:, description:}`), the
  program's Port, its log and metadata records, and the watchdog that
  stops a driver whose program stops delivering frames.
  """
  require Logger

  alias VisionCore.Camera.LibCamera

  @log_tag 2
  @metadata_tag 3
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
  (tag 3) as `VisionCore.Camera.LibCamera.parse_record/1` reads it, and
  `{:error, :malformed_record}` for anything else.
  """
  @spec parse_record(binary()) ::
          {:log, Logger.level(), binary()} | {:metadata, map()} | {:error, :malformed_record}
  def parse_record(<<@log_tag, level, message::binary>>), do: {:log, log_level(level), message}
  def parse_record(<<@metadata_tag, _rest::binary>> = record), do: LibCamera.parse_record(record)
  def parse_record(_other), do: {:error, :malformed_record}

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_), do: :error

  @doc """
  Runs the program, `opts`'s `:executable` or `priv/v4l2_capture`, with
  `arguments`, and starts the watchdog. Returns the fields the watchdog
  reads (`watchdog/2`): `:port`, `:started_at`, `:last_frame_at` (`nil`),
  and the given `:stall_timeout_ms` and `:startup_timeout_ms`. Raises,
  naming `who`, when the program is missing.
  """
  @spec open(keyword(), [String.t()], keyword(), String.t()) :: map()
  def open(opts, arguments, timeouts, who) do
    executable = Keyword.get_lazy(opts, :executable, fn -> binary_path(who) end)

    unless File.exists?(executable) do
      raise "#{who}: v4l2_capture missing at #{executable}; " <>
              "the :okdo_c100 and :arduino_ventuno_q firmware builds provide it."
    end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: arguments
      ])

    Process.send_after(self(), :watchdog, @watchdog_interval_ms)

    %{
      port: port,
      started_at: now_ms(),
      last_frame_at: nil,
      stall_timeout_ms: Keyword.fetch!(timeouts, :stall_timeout_ms),
      startup_timeout_ms: Keyword.fetch!(timeouts, :startup_timeout_ms)
    }
  end

  @doc """
  The watchdog's check of `state`, which holds the fields `open/4`
  returns: `{:noreply, state}`, the next check scheduled, while frames
  come, `{:stop, {:camera_stall, verdict}, state}`, logged with `who`,
  once none came within `:startup_timeout_ms` of the start or within
  `:stall_timeout_ms` of the last frame.
  """
  @spec watchdog(map(), String.t()) :: {:noreply, map()} | {:stop, term(), map()}
  def watchdog(state, who) do
    case LibCamera.stall_verdict(state, now_ms()) do
      :ok ->
        Process.send_after(self(), :watchdog, @watchdog_interval_ms)
        {:noreply, state}

      verdict ->
        Logger.error("#{who} v4l2_capture stopped delivering: #{inspect(verdict)}")
        {:stop, {:camera_stall, verdict}, state}
    end
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
