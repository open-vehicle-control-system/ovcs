defmodule VmsCore.Components.Volkswagen.Polo9N.Dashboard do
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.Bus

  @max_rotation_per_minute 10000
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{contact_source: contact_source, rotation_per_minute_source: rotation_per_minute_source}) do
    :ok = Emitter.configure(:polo_drive, "engine_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "rotations_per_minute" => 0
      }
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")
    {:ok, %{
      loop_timer: timer,
      contact: :off,
      enabled: false,
      contact_source: contact_source,
      rotation_per_minute_source: rotation_per_minute_source
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        Emitter.enable(:polo_drive, "engine_status")
        {:noreply, %{state | enabled: true}}
      {true, :off} ->
        Emitter.disable(:polo_drive, "engine_status")
        {:noreply, %{state | enabled: false}}
      _ ->
        {:noreply, state}
    end
  end
  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{name: :rotation_per_minute, value: rotation_per_minute, source: source}, state) when source == state.rotation_per_minute_source do
    rotation_per_minute = case D.gt?(rotation_per_minute, @max_rotation_per_minute) do
      true  -> 0
      false -> rotation_per_minute
    end
    :ok = Emitter.update(:polo_drive, "engine_status", fn (data) ->
      %{data | "rotations_per_minute" => rotation_per_minute}
    end)
    {:noreply, state}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end
end
