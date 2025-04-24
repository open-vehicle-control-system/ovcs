defmodule VmsCore.Components.Volkswagen.Polo9N.FakeOilPressureSensor do
  @moduledoc """
    Fale oil pressure indicator sensor to avoid alerts on the original dashboard
  """
  use GenServer
  alias VmsCore.{
    Bus,
    Components.OVCS.GenericController
  }

  @loop_period 10
  @rotation_per_minute_activation_treshold 800

  @impl true
  def init(%{
    controller: controller,
    relay_pin: relay_pin,
    rotation_per_minute_source: rotation_per_minute_source})
  do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      relay_pin: relay_pin,
      rotation_per_minute_source: rotation_per_minute_source,
      rotation_per_minute: 0,
      enabled: false
    }}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_relay()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :rotation_per_minute, value: rotation_per_minute, source: source}, state) when source == state.rotation_per_minute_source do
    {:noreply, %{state | rotation_per_minute: rotation_per_minute}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp toggle_relay(state) do
    cond do
      !state.enabled && state.rotation_per_minute >= @rotation_per_minute_activation_treshold ->
        :ok = GenericController.set_digital_value(state.controller, state.relay_pin, true)
        %{state | enabled: true}
      state.enabled && state.rotation_per_minute < @rotation_per_minute_activation_treshold ->
        :ok = GenericController.set_digital_value(state.controller, state.relay_pin, false)
        %{state | enabled: false}
      true ->
        state
    end
  end
end
