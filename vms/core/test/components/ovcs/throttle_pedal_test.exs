defmodule VmsCore.Components.OVCS.ThrottlePedalTest do
  @moduledoc """
  Track B checks track A: a lasting gap faults and holds the throttle at
  zero, and only a released pedal with agreeing tracks clears it.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Decimal, as: D
  alias VmsCore.Components.OVCS.ThrottlePedal

  defp state do
    %{
      cross_check_tolerance: D.new("0.1"),
      cross_check_hold_ms: 100,
      cross_check_gap: nil,
      mismatch_since: nil,
      cross_check_fault: false
    }
  end

  defp check(state, a, b, now), do: ThrottlePedal.cross_check(state, D.new(a), D.new(b), now)

  test "tracks within the tolerance never fault" do
    state = state() |> check("0.50", "0.45", 0) |> check("0.50", "0.45", 1000)

    refute state.cross_check_fault
    assert D.eq?(state.cross_check_gap, D.new("0.05"))
  end

  test "a gap shorter than the hold is noise, not a fault" do
    state = state() |> check("0.50", "0.20", 0) |> check("0.50", "0.20", 99)
    refute state.cross_check_fault

    state = check(state, "0.50", "0.48", 150)
    refute state.cross_check_fault
    assert is_nil(state.mismatch_since)
  end

  test "a gap held for the hold faults, and is logged once" do
    log =
      capture_log(fn ->
        state = state() |> check("0.50", "0.20", 0) |> check("0.50", "0.20", 100)
        assert state.cross_check_fault

        state = check(state, "0.50", "0.20", 110)
        assert state.cross_check_fault
      end)

    assert length(String.split(log, "Throttle pedal tracks disagree")) == 2
  end

  test "agreeing tracks under a pressed pedal keep the fault" do
    state =
      state()
      |> check("0.50", "0.20", 0)
      |> check("0.50", "0.20", 100)
      |> check("0.50", "0.50", 200)

    assert state.cross_check_fault
  end

  test "a released pedal with agreeing tracks clears the fault" do
    state =
      state()
      |> check("0.50", "0.20", 0)
      |> check("0.50", "0.20", 100)
      |> check("0.05", "0.03", 200)

    refute state.cross_check_fault
  end

  test "a released pedal with disagreeing tracks keeps the fault" do
    state =
      state()
      |> check("0.50", "0.20", 0)
      |> check("0.50", "0.20", 100)
      |> check("0.00", "0.30", 200)

    assert state.cross_check_fault
  end
end
