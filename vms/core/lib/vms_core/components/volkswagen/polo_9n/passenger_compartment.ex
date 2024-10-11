defmodule VmsCore.Components.Volkswagen.Polo9N.PassengerCompartment do
  @moduledoc """
    Polo passenger compartment
  """
  use GenServer

  require Logger
  alias Cantastic.{Frame, Receiver, Signal}
  alias VmsCore.Bus
  @loop_period 10

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :polo_drive, ["car_status", "handbrake_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      front_left_door_open: false,
      front_right_door_open: false,
      rear_left_door_open: false,
      rear_right_door_open: false,
      trunk_door_open: false,
      beam_active: false,
      handbrake_engaged: false,
      loop_timer: timer
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{name: :front_left_door_open, value: state.front_left_door_open, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :front_right_door_open, value: state.front_right_door_open, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :rear_left_door_open, value: state.rear_left_door_open, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :rear_right_door_open, value: state.rear_right_door_open, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :trunk_door_open, value: state.trunk_door_open, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :beam_active, value: state.beam_active, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :handbrake_engaged, value: state.handbrake_engaged, source: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name:  "car_status", signals: signals}}, state) do
    %{
      "front_left_door_open" => %Signal{value: front_left_door_open},
      "front_right_door_open" => %Signal{value: front_right_door_open},
      "rear_left_door_open" => %Signal{value: rear_left_door_open},
      "rear_right_door_open" => %Signal{value: rear_right_door_open},
      "trunk_door_open" => %Signal{value: trunk_door_open},
      "beam_active" => %Signal{value: beam_active},
    } = signals
    {:noreply, %{state |
      front_left_door_open: front_left_door_open,
      front_right_door_open: front_right_door_open,
      rear_left_door_open: rear_left_door_open,
      rear_right_door_open: rear_right_door_open,
      trunk_door_open: trunk_door_open,
      beam_active: beam_active
    }}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name:  "handbrake_status", signals: signals}}, state) do
    %{"handbrake_engaged" => %Signal{value: handbrake_engaged}} = signals
    {:noreply, %{state | handbrake_engaged: handbrake_engaged}
  }
  end
end
