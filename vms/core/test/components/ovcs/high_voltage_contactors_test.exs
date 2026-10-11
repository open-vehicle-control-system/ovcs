defmodule VmsCore.Components.OVCS.HighVoltageContactorsTest do
  @moduledoc """
  The end of precharge: the precharge relay opens once the relay
  operating delay has passed, whenever the next loop tick comes.
  """
  use ExUnit.Case, async: true

  alias VmsCore.Components.OVCS.HighVoltageContactors

  defmodule FakeController do
    @moduledoc false
    use GenServer

    def start_link(pins), do: GenServer.start_link(__MODULE__, pins)

    @impl GenServer
    def init(pins), do: {:ok, pins}

    @impl GenServer
    def handle_call({:set_digital_value, pin, enabled}, _from, pins),
      do: {:reply, :ok, Map.put(pins, pin, enabled)}

    def handle_call({:get_digital_value, pin}, _from, pins),
      do: {:reply, {:ok, Map.fetch!(pins, pin)}, pins}
  end

  defp precharge_complete(precharge_ending_time_ms) do
    {:ok, controller} =
      FakeController.start_link(%{main_negative: true, main_positive: true, precharge: true})

    %{
      contact_source: :ignition,
      contact: :on,
      controller: controller,
      main_negative_relay_pin: :main_negative,
      main_positive_relay_pin: :main_positive,
      precharge_relay_pin: :precharge,
      status: :precharge_complete,
      inverter_output_voltage: 400,
      inverter_output_voltage_source: :inverter,
      required_precharge_output_voltage: 380,
      precharge_ending_time_ms: precharge_ending_time_ms,
      loop_timer: nil,
      main_negative_relay_enabled: true,
      main_positive_relay_enabled: true,
      precharge_relay_enabled: true,
      ready_to_drive: false
    }
  end

  defp loop(state) do
    {:noreply, state} = HighVoltageContactors.handle_info(:loop, state)
    state
  end

  test "opens the precharge relay on a tick that comes after the delay" do
    state = precharge_complete(System.monotonic_time(:millisecond) - 1_000) |> loop()

    assert state.status == :started
    assert state.ready_to_drive
  end

  test "keeps the precharge relay closed until the delay has passed" do
    state = precharge_complete(System.monotonic_time(:millisecond) + 60_000) |> loop()

    assert state.status == :precharge_complete
    refute state.ready_to_drive
  end

  test "times the delay on the monotonic clock" do
    starting = %{precharge_complete(0) | status: :starting}
    before_ms = System.monotonic_time(:millisecond)
    state = loop(starting)

    assert state.status == :precharge_complete
    assert state.precharge_ending_time_ms > before_ms
    assert state.precharge_ending_time_ms <= System.monotonic_time(:millisecond) + 1_000
  end
end
