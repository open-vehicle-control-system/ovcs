defmodule VisionCore.Camera.FocusSweep do
  @moduledoc """
  Finds the lens position that suits both stereo cameras: steps the
  shared `focus` camera setting through a range, measures both cameras'
  sharpness at each step (`VisionCore.Stereo.Stage.Sharpness`, through
  `VisionCore.Status`), and sets the position where the camera further
  from its own sharpest is closest to it. Run it from IEx on the unit,
  facing a textured scene at the distance that matters:

      VisionCore.Camera.FocusSweep.run(from: 380, to: 480, step: 10)

  Each step waits a status tick for the lenses and the averages to
  settle, then reads the next, about two seconds a step by default.
  """

  alias VisionCore.Camera.V4L2
  alias VisionCore.Status

  @type result :: %{focus: non_neg_integer(), left: float(), right: float()}

  @doc """
  Sweeps and returns `{:ok, %{best: focus, results: [result]}}`, results
  in focus order, or why a step could not be measured.

  ## Options

    * `:from` (`380`), `:to` (`480`), `:step` (`10`) — the positions tried.
    * `:set` (`true`) — set the best position at the end.
    * `:set_focus`, `:measure` — how a position is set and both cameras'
      sharpness read: the stereo unit's V4L2 cameras and status by default.
  """
  @spec run(keyword()) ::
          {:ok, %{best: non_neg_integer(), results: [result()]}} | {:error, String.t()}
  def run(opts \\ []) do
    set_focus = Keyword.get_lazy(opts, :set_focus, fn -> &set_v4l2_focus/1 end)
    measure = Keyword.get_lazy(opts, :measure, &status_measure/0)

    positions =
      Keyword.get(opts, :from, 380)..Keyword.get(opts, :to, 480)//Keyword.get(opts, :step, 10)

    with {:ok, results} <- sweep(positions, set_focus, measure) do
      best = best(results)
      if Keyword.get(opts, :set, true), do: set_focus.(best)
      {:ok, %{best: best, results: results}}
    end
  end

  defp sweep(positions, set_focus, measure) do
    Enum.reduce_while(positions, {:ok, []}, fn focus, {:ok, results} ->
      with :ok <- set_focus.(focus),
           {:ok, %{left: left, right: right}} <- measure.() do
        {:cont, {:ok, results ++ [%{focus: focus, left: left, right: right}]}}
      else
        other -> {:halt, {:error, "no sharpness at focus #{focus}: #{inspect(other)}"}}
      end
    end)
  end

  # Where the camera further from its own peak is nearest it.
  defp best(results) do
    peak = fn side -> results |> Enum.map(& &1[side]) |> Enum.max() |> max(1.0e-12) end
    {left_peak, right_peak} = {peak.(:left), peak.(:right)}

    results
    |> Enum.max_by(&min(&1.left / left_peak, &1.right / right_peak))
    |> Map.fetch!(:focus)
  end

  # The right camera forwards its settings to the left, which drives both lenses.
  defp set_v4l2_focus(focus) do
    case V4L2.set_controls(V4L2.name_for("left"), focus: focus) do
      {:ok, _controls} -> :ok
      error -> error
    end
  end

  defp status_measure do
    :ok = Status.subscribe()

    fn ->
      flush_status()

      with {:ok, _settling} <- next_status(),
           {:ok, %{sharpness: %{} = sharpness}} <- next_status(),
           do: {:ok, sharpness}
    end
  end

  defp next_status do
    receive do
      {:vision_status, snapshot} -> {:ok, snapshot}
    after
      5_000 -> {:error, :no_status}
    end
  end

  defp flush_status do
    receive do
      {:vision_status, _snapshot} -> flush_status()
    after
      0 -> :ok
    end
  end
end
