defmodule VmsCore.VwPolo.PassengerCompartment do
  use GenServer

  require Logger
  alias Cantastic.{Frame, Signal}

  @network_name :polo_drive

  @car_status_frame_name "car_status"
  @handbrake_status_frame_name "handbrake_status"

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, [@car_status_frame_name, @handbrake_status_frame_name])
    {:ok, %{
      front_left_door_open: false,
      front_right_door_open: false,
      rear_left_door_open: false,
      rear_right_door_open: false,
      trunk_door_open: false,
      beam_active: false,
      handbrake_engaged: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name:  @car_status_frame_name, signals: signals}}, state) do
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
      }
    }
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name:  @handbrake_status_frame_name, signals: signals}}, state) do
    %{"handbrake_engaged" => %Signal{value: handbrake_engaged}} = signals
    {:noreply, %{state | handbrake_engaged: handbrake_engaged}
  }
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end
end
