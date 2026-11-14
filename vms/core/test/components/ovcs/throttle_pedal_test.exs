defmodule VmsCore.Components.OVCS.ThrottlePedalTest do
  @moduledoc """
  The throttle request stays within `[0, 1]` when a track reads outside
  its calibrated range. Track B checks track A: a lasting gap faults and
  holds the throttle at zero, and only a released pedal with agreeing
  tracks clears it.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Decimal, as: D
  alias VmsCore.Components.OVCS.ThrottlePedal

  defmodule FakeController do
    @moduledoc "Answers analog reads with fixed values per pin."
    use GenServer

    def start_link(values_by_pin), do: GenServer.start_link(__MODULE__, values_by_pin)

    @impl GenServer
    def init(values_by_pin), do: {:ok, values_by_pin}

    @impl GenServer
    def handle_call({:get_analog_value, pin}, _from, values_by_pin) do
      {:reply, {:ok, Map.fetch!(values_by_pin, pin)}, values_by_pin}
    end
  end

  defp cross_check_state do
    %{
      cross_check_tolerance: D.new("0.1"),
      cross_check_hold_ms: 100,
      cross_check_gap: nil,
      mismatch_since: nil,
      cross_check_fault: false
    }
  end

  defp pedal_state(controller, overrides) do
    cross_check_state()
    |> Map.merge(%{
      controller: controller,
      throttle_a_pin: :a,
      throttle_b_pin: :b,
      throttle_calibration_status: "disabled",
      raw_max_throttle: ThrottlePedal.raw_max_throttle(),
      low_raw_throttle_a: 1_000,
      high_raw_throttle_a: 9_000,
      low_raw_throttle_b: 1_000,
      high_raw_throttle_b: 9_000,
      raw_throttle_a: 0,
      raw_throttle_b: 0,
      requested_throttle: D.new(0),
      calibrated: true
    })
    |> Map.merge(overrides)
  end

  defp looped(raw_throttle_a, raw_throttle_b, overrides \\ %{}) do
    controller = start_supervised!({FakeController, %{a: raw_throttle_a, b: raw_throttle_b}})
    {:noreply, state} = ThrottlePedal.handle_info(:loop, pedal_state(controller, overrides))
    state
  end

  defp requested_throttle(raw_throttle), do: looped(raw_throttle, raw_throttle).requested_throttle

  defp check(state, a, b, now), do: ThrottlePedal.cross_check(state, D.new(a), D.new(b), now)

  describe "the request" do
    test "a reading below the calibrated low requests zero" do
      assert requested_throttle(900) |> D.equal?(0)
    end

    test "a reading above the calibrated high requests one" do
      assert requested_throttle(9_500) |> D.equal?(1)
    end

    test "a reading within the range is its position in it" do
      assert requested_throttle(5_000) |> D.equal?(D.new("0.5"))
    end

    test "a cross-check fault holds it at zero" do
      state = looped(5_000, 1_000, %{cross_check_hold_ms: 0})

      assert state.cross_check_fault
      assert D.equal?(state.requested_throttle, 0)
    end
  end

  describe "the cross-check" do
    test "tracks within the tolerance never fault" do
      state = cross_check_state() |> check("0.50", "0.45", 0) |> check("0.50", "0.45", 1000)

      refute state.cross_check_fault
      assert D.eq?(state.cross_check_gap, D.new("0.05"))
    end

    test "a gap shorter than the hold is noise, not a fault" do
      state = cross_check_state() |> check("0.50", "0.20", 0) |> check("0.50", "0.20", 99)
      refute state.cross_check_fault

      state = check(state, "0.50", "0.48", 150)
      refute state.cross_check_fault
      assert is_nil(state.mismatch_since)
    end

    test "a gap held for the hold faults, and is logged once" do
      log =
        capture_log(fn ->
          state = cross_check_state() |> check("0.50", "0.20", 0) |> check("0.50", "0.20", 100)
          assert state.cross_check_fault

          state = check(state, "0.50", "0.20", 110)
          assert state.cross_check_fault
        end)

      assert length(String.split(log, "Throttle pedal tracks disagree")) == 2
    end

    test "agreeing tracks under a pressed pedal keep the fault" do
      state =
        cross_check_state()
        |> check("0.50", "0.20", 0)
        |> check("0.50", "0.20", 100)
        |> check("0.50", "0.50", 200)

      assert state.cross_check_fault
    end

    test "a released pedal with agreeing tracks clears the fault" do
      state =
        cross_check_state()
        |> check("0.50", "0.20", 0)
        |> check("0.50", "0.20", 100)
        |> check("0.05", "0.03", 200)

      refute state.cross_check_fault
    end

    test "a released pedal with disagreeing tracks keeps the fault" do
      state =
        cross_check_state()
        |> check("0.50", "0.20", 0)
        |> check("0.50", "0.20", 100)
        |> check("0.00", "0.30", 200)

      assert state.cross_check_fault
    end
  end
end
