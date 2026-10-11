defmodule VmsCore.Components.OVCS.WaterPump do
  @moduledoc """
  Switches a water pump's power relay on a generic controller: on in
  `:drive` or `:reverse`, off in `:parking`.

  ## Options

    * `:controller`, `:power_relay_pin` — the relay's digital pin.
    * `:selected_gear_source` — publishes `:selected_gear`.
  """
  use GenServer
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period_ms 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{
        controller: controller,
        power_relay_pin: power_relay_pin,
        selected_gear_source: selected_gear_source
      }) do
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)
    Bus.subscribe("messages")

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       power_relay_pin: power_relay_pin,
       selected_gear: :parking,
       selected_gear_source: selected_gear_source,
       enabled: false
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_water_pump()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state)
      when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp toggle_water_pump(state) do
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
