defmodule VmsCore.Components.Volkswagen.Polo9N.Dashboard do
  @moduledoc """
  The Volkswagen Polo 9N instrument cluster: while the contact is on,
  emits the `engine_status` frame on the CAN network named by `:network` so the
  rev counter shows the rpm published by `:rotation_per_minute_source`.
  """
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @max_rotation_per_minute 10_000
  @loop_period_ms 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{
        network: network,
        contact_source: contact_source,
        rotation_per_minute_source: rotation_per_minute_source
      }) do
    :ok =
      Emitter.configure(network, "engine_status", %{
        parameters_builder_function: :default,
        initial_data: %{
          "rotations_per_minute" => 0
        }
      })

    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)
    Bus.subscribe("messages")

    {:ok,
     %{
       network: network,
       loop_timer: timer,
       contact: :off,
       enabled: false,
       contact_source: contact_source,
       rotation_per_minute_source: rotation_per_minute_source
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        Emitter.enable(state.network, "engine_status")
        {:noreply, %{state | enabled: true}}

      {true, :off} ->
        Emitter.disable(state.network, "engine_status")
        {:noreply, %{state | enabled: false}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state)
      when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  def handle_info(
        %Bus.Message{name: :rotation_per_minute, value: rotation_per_minute, source: source},
        state
      )
      when source == state.rotation_per_minute_source do
    displayed_rotation_per_minute =
      case D.gt?(rotation_per_minute, @max_rotation_per_minute) do
        true -> 0
        false -> rotation_per_minute
      end

    :ok =
      Emitter.update(state.network, "engine_status", fn emitter_data ->
        %{emitter_data | "rotations_per_minute" => displayed_rotation_per_minute}
      end)

    {:noreply, state}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end
end
