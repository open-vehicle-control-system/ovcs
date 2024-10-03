defmodule VmsCore.PassengerCompartment do
  use GenServer
  alias Cantastic.Emitter
  alias VmsCore.Bus

  @loop_period 100

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{passenger_compartement_source: passenger_compartment_source}) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    :ok = Emitter.configure(:ovcs, "passenger_compartment_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "front_left_door_open" => false,
        "front_right_door_open" => false,
        "rear_left_door_open" => false,
        "rear_right_door_open" => false,
        "trunk_door_open" => false,
        "beam_active" => false,
        "handbrake_engaged" => false
      },
      enable: true
    })
    Bus.subscribe("messages")
    {:ok, %{
      front_left_door_open: false,
      front_right_door_open: false,
      rear_left_door_open: false,
      rear_right_door_open: false,
      trunk_door_open: false,
      beam_active: false,
      handbrake_engaged: false,
      passenger_compartment_source: passenger_compartment_source,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    :ok = Emitter.update(:ovcs, "passenger_compartment_status", fn (data) ->
      %{data |
      "front_left_door_open" => state.front_left_door_open,
      "front_right_door_open" => state.front_right_door_open,
      "rear_left_door_open" => state.rear_left_door_open,
      "rear_right_door_open" => state.rear_right_door_open,
      "trunk_door_open" => state.trunk_door_open,
      "beam_active" => state.beam_active,
      "handbrake_engaged" => state.handbrake_engaged
    }
    end)
    {:noreply, state}
  end
  def handle_info(%Bus.Message{name: :front_left_door_open, value: front_left_door_open, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | front_left_door_open: front_left_door_open}}
  end
  def handle_info(%Bus.Message{name: :front_right_door_open, value: front_right_door_open, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | front_right_door_open: front_right_door_open}}
  end
  def handle_info(%Bus.Message{name: :rear_left_door_open, value: rear_left_door_open, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | rear_left_door_open: rear_left_door_open}}
  end
  def handle_info(%Bus.Message{name: :rear_right_door_open, value: rear_right_door_open, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | rear_right_door_open: rear_right_door_open}}
  end
  def handle_info(%Bus.Message{name: :trunk_door_open, value: trunk_door_open, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | trunk_door_open: trunk_door_open}}
  end
  def handle_info(%Bus.Message{name: :beam_active, value: beam_active, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | beam_active: beam_active}}
  end
  def handle_info(%Bus.Message{name: :handbrake_engaged, value: handbrake_engaged, source: source}, state) when source == state.passenger_compartment_source do
    {:noreply, %{state | handbrake_engaged: handbrake_engaged}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end
end
