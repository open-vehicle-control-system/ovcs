defmodule VisionCore.Stereo.StageTimer do
  @moduledoc """
  Per-stage timing for the stereo unit's processes. Lives inside the
  GenServer that's already on the hot path (no extra message hops, no
  ETS, no shared atomics) and flushes a one-line summary every
  `:window` samples.

  Usage pattern:

      state = %{timer: StageTimer.new(window: 30, label: "pipeline")}

      {duration_ns, value} = :timer.tc(fn -> work() end, :nanosecond)
      state = update_in(state.timer, &StageTimer.record(&1, :match, duration_ns))

      # Increment a counter (drops, etc.) without timing
      state = update_in(state.timer, &StageTimer.bump(&1, :drop_busy))

      # Mark one pair; flushes when the window is full.
      state = update_in(state.timer, &StageTimer.tick(&1))

  `tick/1` returns the same struct; the side effect on
  every Nth call is a `Logger.info/1` line. There's no out-of-band
  reporter — the goal is "see numbers in the vision core's tty" not
  "build a metrics pipeline".
  """
  require Logger

  defstruct window: 30,
            label: "stereo",
            count: 0,
            stages: %{},
            counters: %{},
            scalars: %{}

  @typedoc """
  `stages` holds durations in nanoseconds, most recent first;
  `scalars` holds dimensionless or custom-unit samples, formatted apart
  from the stage timings. All three reset at each flush.
  """
  @type t :: %__MODULE__{
          window: pos_integer(),
          label: String.t(),
          count: non_neg_integer(),
          stages: %{atom() => [integer()]},
          counters: %{atom() => non_neg_integer()},
          scalars: %{atom() => [{number(), String.t()}]}
        }

  @doc "A new accumulator; `:window` (30) samples per flush, `:label` (`\"stereo\"`) in the log line."
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
  def record(%__MODULE__{} = timer, stage, duration_ns)
      when is_atom(stage) and is_integer(duration_ns) do
    %{timer | stages: Map.update(timer.stages, stage, [duration_ns], &[duration_ns | &1])}
  end

  @doc """
  Increment a named counter by 1. Counters reset every flush.
  """
  def bump(%__MODULE__{} = timer, counter) when is_atom(counter) do
    %{timer | counters: Map.update(timer.counters, counter, 1, &(&1 + 1))}
  end

  @doc """
  Record a dimensionless or custom-unit scalar (e.g. valid_ratio
  in %, mean disparity in px). Formatted in its own section so the
  ms-scaled stage formatter doesn't mangle the numbers.
  """
  def record_scalar(%__MODULE__{} = timer, name, value, unit \\ "")
      when is_atom(name) and is_number(value) do
    %{
      timer
      | scalars: Map.update(timer.scalars, name, [{value, unit}], &[{value, unit} | &1])
    }
  end

  @doc """
  Mark one completed "unit" (one disparity, one frame, etc.).
  When `count == window`, log a summary and reset. Returns the
  (possibly reset) struct.
  """
  def tick(%__MODULE__{} = timer) do
    count = timer.count + 1

    if count >= timer.window do
      flush(%{timer | count: count})
    else
      %{timer | count: count}
    end
  end

  defp flush(%__MODULE__{} = timer) do
    Logger.info(format(timer))
    %__MODULE__{timer | count: 0, stages: %{}, counters: %{}, scalars: %{}}
  end

  @doc false
  def format(%__MODULE__{} = timer) do
    window_seconds = window_seconds(timer)
    rate_hz = if window_seconds > 0, do: timer.count / window_seconds, else: 0.0

    stages_part =
      timer.stages
      |> Enum.sort_by(fn {stage, _} -> stage end)
      |> Enum.map_join(" ", fn {stage, samples} -> "#{stage}=#{format_samples(samples)}" end)

    counters_part =
      case timer.counters do
        empty when map_size(empty) == 0 ->
          ""

        counters ->
          " | " <>
            Enum.map_join(counters, " ", fn {counter, value} -> "#{counter}=#{value}" end)
      end

    scalars_part =
      case timer.scalars do
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

    "[#{timer.label}] n=#{timer.count} rate=#{Float.round(rate_hz, 2)} Hz | " <>
      stages_part <> counters_part <> scalars_part
  end

  defp format_scalar_samples([{_, unit} | _] = samples) do
    values = Enum.map(samples, fn {value, _} -> value end) |> Enum.sort()
    count = length(values)
    p50 = Enum.at(values, max(round(0.50 * count) - 1, 0))
    p95 = Enum.at(values, max(round(0.95 * count) - 1, 0))
    max_value = List.last(values)

    "#{round_to_hundredths(p50)}/#{round_to_hundredths(p95)}/#{round_to_hundredths(max_value)}#{unit}"
  end

  defp round_to_hundredths(value) when is_float(value), do: Float.round(value, 2)
  defp round_to_hundredths(value), do: value

  # From the :wall samples, else the :total ones, else 0.
  defp window_seconds(%__MODULE__{stages: stages}) do
    cond do
      Map.has_key?(stages, :wall) -> Enum.sum(stages.wall) / 1_000_000_000
      Map.has_key?(stages, :total) -> Enum.sum(stages.total) / 1_000_000_000
      true -> 0.0
    end
  end

  defp format_samples(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    p50 = percentile_ms(sorted, count, 0.50)
    p95 = percentile_ms(sorted, count, 0.95)
    max_ms = percentile_ms(sorted, count, 1.00)

    "#{p50}/#{p95}/#{max_ms}"
  end

  defp percentile_ms(sorted_samples, count, quantile) do
    index = max(min(round(quantile * count) - 1, count - 1), 0)
    nanoseconds = Enum.at(sorted_samples, index)
    Float.round(nanoseconds / 1_000_000, 1)
  end
end
