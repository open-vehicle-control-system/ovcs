defmodule VmsCore.NissanLeaf.Em57.Charger do
  use GenServer

  @network_name :leaf_drive
  @charger_status_frame_name "charger_status"

  @impl true
  def init(_) do
    :ok = init_emitters()
    Receiver.subscribe(self(), @network_name, [@charger_status_frame_name])
    {:ok, %{
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, @vms_alive_frame_name, %{
      parameters_builder_function: &alive_frame_parameters_builder/1,
      initial_data: nil
    })
    :ok = Emitter.configure(@network_name, @vms_torque_request_frame_name, %{
      parameters_builder_function: &torque_frame_parameters_builder/1,
      initial_data: %{
        "requested_torque" => @zero,
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@network_name, @vms_status_frame_name, %{
      parameters_builder_function: &status_frame_parameters_builder/1,
      initial_data: %{
        "gear" => "drive",
        "counter" => 0
      }
    })
    :ok
  end

  def status_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "gear" => data["gear"],
      "heartbeat" => rem(counter, 2),
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }

    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end
end
