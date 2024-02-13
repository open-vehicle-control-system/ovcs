defmodule OvcsEcu.NissanLeaf.Em57.Inverter do
  use GenServer

  alias OvcsEcu.NissanLeaf.Util
  alias Cantastic.Emitter

  @network_name "drive"

  @impl true
  def init(_) do
    :ok = init_emitters()
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, "vmsAlive", %{
      parameters_builder_function: &alive_frame_parameters_builder/1,
      initial_data: nil
    })
    :ok = Emitter.configure(@network_name, "vmsTorqueRequest", %{
      parameters_builder_function: &torque_frame_parameters_builder/1,
      initial_data: %{
        "torque" => 0,
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@network_name, "vmsStatus", %{
      parameters_builder_function: &status_frame_parameters_builder/1,
      initial_data: %{
        "gear" => "parked",
        "counter" => 0
      }
    })
    :ok
  end

  def alive_frame_parameters_builder(state) do
    {:ok, nil, state}
  end

  def torque_frame_parameters_builder(state) do
    counter = state.data["counter"]
    parameters = %{
      "torque" => state.data["torque"],
      "counter" => Util.shifted_counter(counter),
      "crc" => &Util.crc8/1
    }

    state = state |> put_in([:data, "counter"], Util.counter(counter + 1))
    {:ok, parameters, state}
  end

  def status_frame_parameters_builder(state) do
    counter = state.data["counter"]
    parameters = %{
      "gear" => state.data["gear"],
      "heartbeat" => rem(counter, 2),
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }

    state = state |> put_in([:data, "counter"], Util.counter(counter + 1))
    {:ok, parameters, state}
  end

  def on() do
    Emitter.batch_enable(@network_name, ["vmsAlive", "vmsTorqueRequest", "vmsStatus"])
  end

  def off() do
    Emitter.batch_disable(@network_name, ["vmsAlive", "vmsTorqueRequest", "vmsStatus"])
  end

  def throttle(torque) do
    Emitter.update(@network_name, "vmsTorqueRequest", fn (state) ->
      state |> put_in([:data, "torque"], torque)
    end)
  end

  def ready_to_drive?() do
    false
  end
end
