defmodule VmsCore.Components.Volkswagen.Polo9N.FakeOilPressureSensor do
  @moduledoc """
  Stands in for the Volkswagen Polo 9N's oil pressure switch so the
  original instrument cluster raises no oil pressure warning: closes a
  generic controller relay (`:controller`, `:relay_pin`) while the rpm
  published by `:rotation_per_minute_source` is at or above a threshold.
  An unknown (`nil`) rpm leaves the relay as it is.
  """
  use GenServer
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period_ms 10
  @relay_closing_rotation_per_minute 800

  @impl GenServer
  def init(%{
        controller: controller,
        relay_pin: relay_pin,
        rotation_per_minute_source: rotation_per_minute_source
      }) do
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)
    Bus.subscribe("messages")

    {:ok,
     %{
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

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_relay()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{name: :rotation_per_minute, value: rotation_per_minute, source: source},
        state
      )
      when source == state.rotation_per_minute_source do
    {:noreply, %{state | rotation_per_minute: rotation_per_minute}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp toggle_relay(%{rotation_per_minute: nil} = state), do: state

  defp toggle_relay(state) do
    cond do
      !state.enabled && state.rotation_per_minute >= @relay_closing_rotation_per_minute ->
        :ok = GenericController.set_digital_value(state.controller, state.relay_pin, true)
        %{state | enabled: true}

      state.enabled && state.rotation_per_minute < @relay_closing_rotation_per_minute ->
        :ok = GenericController.set_digital_value(state.controller, state.relay_pin, false)
        %{state | enabled: false}

      true ->
        state
    end
  end
end
