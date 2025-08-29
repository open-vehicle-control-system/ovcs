defmodule VmsCore.Vehicles.OVCS1.OVCSCANForwarder do
  @moduledoc """
    Forward the required metrics on the OVCS CAN bus
  """
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.Bus

  @loop_period 100
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{passenger_compartement_source: passenger_compartment_source, speed_source: speed_source}) do
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
    :ok = Emitter.configure(:ovcs, "drivetrain_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "speed" => @zero,
        "rotation_per_minute" => @zero
      },
      enable: true
    })
    Bus.subscribe("messages")
    {:ok, %{
      front_left_door_open: false,
      emitted_front_left_door_open: false,
      front_right_door_open: false,
      emitted_front_right_door_open: false,
      rear_left_door_open: false,
      emitted_rear_left_door_open: false,
      rear_right_door_open: false,
      emitted_rear_right_door_open: false,
      trunk_door_open: false,
      emitted_trunk_door_open: false,
      beam_active: false,
      emitted_beam_active: false,
      handbrake_engaged: false,
      emitted_handbrake_engaged: false,
      speed: @zero,
      emitted_speed: @zero,
      passenger_compartment_source: passenger_compartment_source,
      speed_source: speed_source,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> adapt_speed()
      |> adapt_compartment_status(:front_left_door_open, :emitted_front_left_door_open)
      |> adapt_compartment_status(:front_right_door_open, :emitted_front_right_door_open)
      |> adapt_compartment_status(:rear_left_door_open, :emitted_rear_left_door_open)
      |> adapt_compartment_status(:rear_right_door_open, :emitted_rear_right_door_open)
      |> adapt_compartment_status(:trunk_door_open, :emitted_trunk_door_open)
      |> adapt_compartment_status(:beam_active, :emitted_beam_active)
      |> adapt_compartment_status(:handbrake_engaged, :emitted_handbrake_engaged)
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
  def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state) when source == state.speed_source do
    {:noreply, %{state | speed: speed}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp adapt_speed(state) do
    case state.emitted_speed == state.speed do
      true -> state
      false ->
        :ok = Emitter.update(:ovcs, "drivetrain_status", fn (data) ->
          %{data | "speed" => state.speed}
        end)
        %{state | emitted_speed: state.speed}
    end
  end

  defp adapt_compartment_status(state, key, emitted_key) do
    new_value = state[key]
    case state[emitted_key] == new_value do
      true -> state
      false ->
        :ok = Emitter.update(:ovcs, "passenger_compartment_status", fn (data) ->
          %{data | "#{key}" => new_value}
        end)
        %{state | emitted_key => new_value}
    end
  end
end
