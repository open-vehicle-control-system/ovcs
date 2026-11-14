defmodule VisionCore.StageTimes do
  @moduledoc """
  The time a pipeline's stages took, summed over the pairs or frames of
  a window, and what `VisionCore.Status` reports of them (`summary/1`).

  A stage is timed under its name. A run of stages timed as one, as the
  stereo pipeline's segments are (`VisionCore.Stereo.Pipeline`), is
  timed under its members' names joined with `+`; its members may be
  timed under their own names too.
  """

  @typedoc "Each stage's time over a window: the sum in milliseconds, and how many times it ran."
  @type t :: %{atom() => {sum_ms :: float(), count :: non_neg_integer()}}

  @typedoc """
  A window's times: each stage's mean time in milliseconds, `nil` for
  one that did not run; the runs timed as one whose members have no time
  of their own, each with its mean time; and `:total_ms`, the stages'
  and runs' times added up, a run and its members counted once, `nil`
  when none ran.
  """
  @type summary :: %{
          total_ms: float() | nil,
          stages: %{atom() => float() | nil},
          segments: [%{stages: [atom()], ms: float()}]
        }

  @doc "No time yet for each of `stages`."
  @spec new([atom()]) :: t()
  def new(stages \\ []), do: Map.new(stages, &{&1, {0.0, 0}})

  @doc "`times` with one more run of `stage`, which took `duration_ms`."
  @spec add(t(), atom(), number()) :: t()
  def add(times, stage, duration_ms) when is_atom(stage) and is_number(duration_ms) do
    Map.update(times, stage, {duration_ms / 1, 1}, fn {sum_ms, count} ->
      {sum_ms + duration_ms, count + 1}
    end)
  end

  @doc "`times` started over, for the same stages."
  @spec reset(t()) :: t()
  def reset(times), do: new(Map.keys(times))

  @doc "The summary of a window in which nothing was timed."
  @spec none() :: summary()
  def none, do: %{total_ms: nil, stages: %{}, segments: []}

  @doc "What `times` come to: see `t:summary/0`."
  @spec summary(t()) :: summary()
  def summary(times) do
    means = Map.new(times, fn {name, time} -> {name, mean_ms(time)} end)
    {runs, stages} = Enum.split_with(means, fn {name, _mean_ms} -> run?(name) end)
    stages = Map.new(stages)
    runs = for {name, mean_ms} <- runs, mean_ms != nil, do: {members(name), mean_ms}
    in_a_run = for {members, _mean_ms} <- runs, member <- members, into: MapSet.new(), do: member

    alone =
      for {name, mean_ms} <- stages, mean_ms != nil, name not in in_a_run, do: mean_ms

    %{
      total_ms: total(alone ++ Enum.map(runs, &elem(&1, 1))),
      stages: stages,
      segments:
        for(
          {members, mean_ms} <- Enum.sort(runs),
          not Enum.all?(members, &Map.has_key?(stages, &1)),
          do: %{stages: members, ms: mean_ms}
        )
    }
  end

  defp mean_ms({_sum_ms, 0}), do: nil
  defp mean_ms({sum_ms, count}), do: sum_ms / count

  defp total([]), do: nil
  defp total(times_ms), do: Enum.sum(times_ms)

  defp run?(name), do: name |> Atom.to_string() |> String.contains?("+")

  # The members are stages of the pipeline that timed the run, so their names exist.
  defp members(name),
    do: name |> Atom.to_string() |> String.split("+") |> Enum.map(&String.to_existing_atom/1)
end
