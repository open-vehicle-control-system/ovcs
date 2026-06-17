defmodule RosBridge.StereoCamera.Telemetry do
  @moduledoc """
  Lightweight per-stage timing accumulator for the stereo
  pipeline. Lives inside the GenServer that's already on the hot
  path (no extra message hops, no ETS, no shared atomics) and
  flushes a one-line summary every `:window` samples.

  Usage pattern:

      state = %{telemetry: Telemetry.new(window: 30, label: "backend")}

      {duration_ns, value} = :timer.tc(fn -> work() end, :nanosecond)
      state = update_in(state.telemetry, &Telemetry.record(&1, :sgbm, duration_ns))

      # Increment a counter (drops, etc.) without timing
      state = update_in(state.telemetry, &Telemetry.bump(&1, :busy_drop))

      # Mark one "result" — pulls anything queued under :sample
      # into the window, flushes when full.
      state = update_in(state.telemetry, &Telemetry.tick(&1))

  `tick/1` returns the same telemetry struct; the side effect on
  every Nth call is a `Logger.info/1` line. There's no out-of-band
  reporter — the goal is "see numbers in the bridge's tty" not
  "build a metrics pipeline".
  """
  require Logger

  defstruct window: 30,
            label: "stereo",
            count: 0,
            # %{stage => [duration_ns, ...]} (most-recent-first; trimmed at flush)
            stages: %{},
            # %{counter_name => integer}
            counters: %{},
            # %{name => [{value :: number, unit :: String.t()}]}  — dimensionless or
            # custom-unit scalars formatted distinctly from time stages
            scalars: %{}

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    %__MODULE__{
      window: Keyword.get(opts, :window, 30),
      label: Keyword.get(opts, :label, "stereo")
    }
  end

  @doc """
  Record a stage duration in nanoseconds. Stages are free-form
  atoms; whichever ones are recorded show up in the next flush.
  """
  def record(%__MODULE__{} = telemetry, stage, duration_ns)
      when is_atom(stage) and is_integer(duration_ns) do
    %{telemetry | stages: Map.update(telemetry.stages, stage, [duration_ns], &[duration_ns | &1])}
  end

  @doc """
  Increment a named counter by 1. Counters reset every flush.
  """
  def bump(%__MODULE__{} = telemetry, counter) when is_atom(counter) do
    %{telemetry | counters: Map.update(telemetry.counters, counter, 1, &(&1 + 1))}
  end

  @doc """
  Record a dimensionless or custom-unit scalar (e.g. valid_ratio
  in %, mean disparity in px). Formatted in its own section so the
  ms-scaled stage formatter doesn't mangle the numbers.
  """
  def record_scalar(%__MODULE__{} = telemetry, name, value, unit \\ "")
      when is_atom(name) and is_number(value) do
    %{
      telemetry
      | scalars: Map.update(telemetry.scalars, name, [{value, unit}], &[{value, unit} | &1])
    }
  end

  @doc """
  Mark one completed "unit" (one disparity, one frame, etc.).
  When `count == window`, log a summary and reset. Returns the
  (possibly reset) struct.
  """
  def tick(%__MODULE__{} = telemetry) do
    count = telemetry.count + 1

    if count >= telemetry.window do
      flush(%{telemetry | count: count})
    else
      %{telemetry | count: count}
    end
  end

  @doc """
  Time `fun`, record under `stage`, return `fun`'s result. Convenience
  for the common case.
  """
  def measure(telemetry_ref, stage, fun) when is_atom(stage) and is_function(fun, 0) do
    start = System.monotonic_time(:nanosecond)
    result = fun.()
    duration = System.monotonic_time(:nanosecond) - start
    {duration, result, stage, telemetry_ref}
  end

  # ── flush / format ───────────────────────────────────────────

  defp flush(%__MODULE__{} = telemetry) do
    Logger.info(format(telemetry))
    %__MODULE__{telemetry | count: 0, stages: %{}, counters: %{}, scalars: %{}}
  end

  @doc false
  def format(%__MODULE__{} = telemetry) do
    window_seconds = window_seconds(telemetry)
    rate = if window_seconds > 0, do: telemetry.count / window_seconds, else: 0.0

    stages_part =
      telemetry.stages
      |> Enum.sort_by(fn {stage, _} -> stage end)
      |> Enum.map_join(" ", fn {stage, samples} -> "#{stage}=#{format_samples(samples)}" end)

    counters_part =
      case telemetry.counters do
        empty when map_size(empty) == 0 ->
          ""

        counters ->
          " | " <>
            Enum.map_join(counters, " ", fn {counter, value} -> "#{counter}=#{value}" end)
      end

    scalars_part =
      case telemetry.scalars do
        empty when map_size(empty) == 0 ->
          ""

        scalars ->
          " | " <>
            (scalars
             |> Enum.sort_by(fn {name, _} -> name end)
             |> Enum.map_join(" ", fn {name, samples} ->
               "#{name}=#{format_scalar_samples(samples)}"
             end))
      end

    "[#{telemetry.label}] n=#{telemetry.count} rate=#{Float.round(rate, 2)} Hz | " <>
      stages_part <> counters_part <> scalars_part
  end

  defp format_scalar_samples([{_, unit} | _] = samples) do
    values = Enum.map(samples, fn {value, _} -> value end) |> Enum.sort()
    n = length(values)
    p50 = Enum.at(values, max(round(0.50 * n) - 1, 0))
    p95 = Enum.at(values, max(round(0.95 * n) - 1, 0))
    max_value = List.last(values)

    "#{round2(p50)}/#{round2(p95)}/#{round2(max_value)}#{unit}"
  end

  defp round2(value) when is_float(value), do: Float.round(value, 2)
  defp round2(value), do: value

  # Total elapsed wall time for the window — best guess from a
  # `:wall` sample if present, otherwise from the sum of a "total"
  # stage if recorded, otherwise 0 (rate then logs as 0).
  defp window_seconds(%__MODULE__{stages: stages}) do
    cond do
      Map.has_key?(stages, :wall) -> Enum.sum(stages.wall) / 1_000_000_000
      Map.has_key?(stages, :total) -> Enum.sum(stages.total) / 1_000_000_000
      true -> 0.0
    end
  end

  defp format_samples(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    p50 = percentile_ms(sorted, n, 0.50)
    p95 = percentile_ms(sorted, n, 0.95)
    max_ms = percentile_ms(sorted, n, 1.00)

    "#{p50}/#{p95}/#{max_ms}"
  end

  defp percentile_ms(sorted_samples, count, quantile) do
    index = max(min(round(quantile * count) - 1, count - 1), 0)
    nanoseconds = Enum.at(sorted_samples, index)
    Float.round(nanoseconds / 1_000_000, 1)
  end
end
