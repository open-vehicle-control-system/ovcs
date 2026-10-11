defmodule VmsCore.Components.OVCS.ThrottlePedalTest do
  @moduledoc """
  The throttle request stays within `[0, 1]` when a track reads outside
  its calibrated range.
  """
  use ExUnit.Case, async: false
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

  defp requested_throttle(raw_throttle_a) do
    controller = start_supervised!({FakeController, %{a: raw_throttle_a, b: 5_000}})

    state = %{
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
    }

    {:noreply, state} = ThrottlePedal.handle_info(:loop, state)
    state.requested_throttle
  end

  test "a reading below the calibrated low requests zero" do
    assert requested_throttle(900) |> D.equal?(0)
  end

  test "a reading above the calibrated high requests one" do
    assert requested_throttle(9_500) |> D.equal?(1)
  end

  test "a reading within the range is its position in it" do
    assert requested_throttle(5_000) |> D.equal?(D.new("0.5"))
  end
end
