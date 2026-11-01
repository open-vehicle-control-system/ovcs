defmodule VisionCore.Camera.FocusSweepTest do
  use ExUnit.Case, async: false

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

  test "refuses a range with no position in it" do
    assert {:error, "no focus position" <> _} = sweep(from: 480, to: 380, step: 10)
  end

  test "fails when the best position cannot be set at the end" do
    calls = :counters.new(1, [])

    set_focus = fn _focus ->
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) > 3, do: {:error, :lens_gone}, else: :ok
    end

    assert {:error, "focus 420 not set" <> _} =
             FocusSweep.run(
               from: 420,
               to: 440,
               step: 10,
               set_focus: set_focus,
               measure: fn -> {:ok, %{left: 1.0, right: 1.0}} end
             )
  end

  # Stands in for VisionCore.Status: a snapshot with both cameras' sharpness every 5 ms.
  defmodule Status do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: VisionCore.Status)
    def subscribers, do: GenServer.call(VisionCore.Status, :subscribers)

    @impl GenServer
    def init(nil) do
      :timer.send_interval(5, :tick)
      {:ok, MapSet.new()}
    end

    @impl GenServer
    def handle_call({:subscribe, pid}, _from, subscribers),
      do: {:reply, :ok, MapSet.put(subscribers, pid)}

    def handle_call({:unsubscribe, pid}, _from, subscribers),
      do: {:reply, :ok, MapSet.delete(subscribers, pid)}

    def handle_call(:subscribers, _from, subscribers), do: {:reply, subscribers, subscribers}

    @impl GenServer
    def handle_info(:tick, subscribers) do
      snapshot = %{sharpness: %{left: 0.02, right: 0.03}}
      Enum.each(subscribers, &send(&1, {:vision_status, snapshot}))
      {:noreply, subscribers}
    end
  end

  test "measures through the status and leaves the caller unsubscribed" do
    start_supervised!(Status)

    assert {:ok, %{results: [_one, _two]}} =
             FocusSweep.run(from: 420, to: 430, step: 10, set_focus: fn _ -> :ok end)

    assert Status.subscribers() == MapSet.new()
    refute_receive {:vision_status, _snapshot}, 50
  end

  test "stops at the first value it cannot measure" do
    assert {:error, "no sharpness" <> _} =
             FocusSweep.run(set_focus: fn _ -> :ok end, measure: fn -> {:error, :no_pairs} end)
  end
end
