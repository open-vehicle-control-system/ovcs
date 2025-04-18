defmodule VmsCore.Components.OVCS.WaterPump do
  @moduledoc """
    Orion BMS
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
    contact_source: contact_source})
  do
    {:ok, _} = :timer.send_after(0, :start)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      power_relay_pin: power_relay_pin,
      contact_source: contact_source,
      contact: :off,
      enabled: false
    }}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_waterpump()
    {:noreply, state}
  end

  defp toggle_waterpump(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        %{state | enabled: true}
      {true, :off} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end
end
