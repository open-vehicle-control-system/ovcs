defmodule VmsCore.PassengerCompartment do
  use GenServer
  alias Cantastic.Emitter

  @network_name :ovcs
  @passenger_compartment_status_frame_name "passenger_compartment_status"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @passenger_compartment_status_frame_name, %{
      parameters_builder_function: &passenger_compartment_status_frame_parameter_builder/1,
      initial_data: %{
        "front_left_door_open" => false,
        "front_right_door_open" => false,
        "rear_left_door_open" => false,
        "rear_right_door_open" => false,
        "trunk_door_open" => false,
        "beam_active" => false,
        "handbrake_engaged" => false
      }
    })
    :ok = Emitter.enable(@network_name, @passenger_compartment_status_frame_name)
    {:ok, %{}}
  end

  defp passenger_compartment_status_frame_parameter_builder(_) do
    {:ok, status} = VmsCore.VwPolo.PassengerCompartment.status()
    parameters = %{
      "front_left_door_open" => status.front_left_door_open,
      "front_right_door_open" => status.front_right_door_open,
      "rear_left_door_open" => status.rear_left_door_open,
      "rear_right_door_open" => status.rear_right_door_open,
      "trunk_door_open" => status.trunk_door_open,
      "beam_active" => status.beam_active,
      "handbrake_engaged" => status.handbrake_engaged
    }
    {:ok, parameters, parameters}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
end
