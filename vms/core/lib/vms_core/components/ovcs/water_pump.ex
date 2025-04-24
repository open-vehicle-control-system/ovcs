defmodule VmsCore.Components.OVCS.WaterPump do
  @moduledoc """
    Generic waterpump relay control
  """
  use GenServer
  alias VmsCore.{
    Bus,
    Components.OVCS.GenericController
  }

  @loop_period 10

  @impl true
  def init(%{
    controller: controller,
    power_relay_pin: power_relay_pin,
    selected_gear_source: selected_gear_source})
  do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      power_relay_pin: power_relay_pin,
      selected_gear: :parking,
      selected_gear_source: selected_gear_source,
      enabled: false
    }}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_waterpump()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state) when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp toggle_waterpump(state) do
    case {state.enabled, state.selected_gear} do
      {true, :parking} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      {false, gear} when gear == :drive or gear == :reverse ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        %{state | enabled: true}
      _ ->
        state
    end
  end
end
