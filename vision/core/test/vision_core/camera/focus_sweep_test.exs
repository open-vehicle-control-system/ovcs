defmodule VisionCore.Camera.FocusSweepTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.FocusSweep

  # Sharpness peaking at `peak`, falling off on both sides.
  defp curve(focus, peak), do: 1.0 / (1.0 + ((focus - peak) / 20) ** 2)

  defp sweep(opts) do
    test_pid = self()
    focus = :counters.new(1, [])

    set_focus = fn value ->
      :counters.put(focus, 1, value)
      send(test_pid, {:focus, value})
      :ok
    end

    measure = fn ->
      value = :counters.get(focus, 1)
      {:ok, %{left: 0.03 * curve(value, 420), right: 0.02 * curve(value, 440)}}
    end

    FocusSweep.run(Keyword.merge([set_focus: set_focus, measure: measure], opts))
  end

  test "steps the focus through the range and records both cameras' sharpness" do
    assert {:ok, %{results: results}} = sweep(from: 400, to: 460, step: 20)
    assert Enum.map(results, & &1.focus) == [400, 420, 440, 460]
    assert Enum.all?(results, &(&1.left > 0 and &1.right > 0))
  end

  test "picks the focus best for both cameras and sets it" do
    assert {:ok, %{best: best}} = sweep(from: 380, to: 480, step: 10)
    assert best == 430
    assert focus_messages() |> Enum.take(-2) == [480, 430]
  end

  test "leaves the focus where the sweep ended with set: false" do
    assert {:ok, %{best: 430}} = sweep(from: 380, to: 480, step: 10, set: false)
    assert focus_messages() |> List.last() == 480
  end

  defp focus_messages do
    receive do
      {:focus, value} -> [value | focus_messages()]
    after
      0 -> []
    end
  end

  test "stops at the first value it cannot measure" do
    assert {:error, "no sharpness" <> _} =
             FocusSweep.run(set_focus: fn _ -> :ok end, measure: fn -> {:error, :no_pairs} end)
  end
end
