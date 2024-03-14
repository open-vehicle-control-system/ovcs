defmodule VmsCore.NissanLeaf.Em57.Inverter do
  use GenServer

  alias VmsCore.NissanLeaf.Util
  alias Cantastic.Emitter

  @network_name :leaf_drive
  @inverter_status_frame_name "inverter_status"
  @vms_alive_frame_name "vms_alive"
  @vms_torque_request_frame_name "vms_torque_request"
  @vms_status_frame_name "vms_status"

  @impl true
  def init(_) do
    :ok = init_emitters()
    Cantastic.Receiver.subscribe(self(), @network_name, @inverter_status_frame_name)
    {:ok, %{
      rpm: 0
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
        "torque" => 0,
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

  @impl true
  def handle_call(:rpm, _from, state) do
    rpm = case state.rpm do
      value when value > 6000 -> 0
      value -> value
    end
    {:reply, rpm, state}
  end

  @impl true
  def handle_info({:handle_frame,  _frame, [_, _, %{value: rpm}] = _signals}, state) do
    {:noreply, %{state | rpm: rpm}}
  end

  def alive_frame_parameters_builder(emitter_state) do
    {:ok, nil, emitter_state}
  end

  def torque_frame_parameters_builder(emitter_state) do
    counter = emitter_state.data["counter"]
    parameters = %{
      "torque" => emitter_state.data["torque"],
      "counter" => Util.shifted_counter(counter),
      "crc" => &Util.crc8/1
    }

    emitter_state = emitter_state |> put_in([:data, "counter"], Util.counter(counter + 1))
    {:ok, parameters, emitter_state}
  end

  def status_frame_parameters_builder(emitter_state) do
    counter = emitter_state.data["counter"]
    parameters = %{
      "gear" => emitter_state.data["gear"],
      "heartbeat" => rem(counter, 2),
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }

    emitter_state = emitter_state |> put_in([:data, "counter"], Util.counter(counter + 1))
    {:ok, parameters, emitter_state}
  end

  def on() do
    Emitter.enable(@network_name, [@vms_alive_frame_name, @vms_torque_request_frame_name, @vms_status_frame_name])
  end

  def off() do
    Emitter.disable(@network_name, [@vms_alive_frame_name, @vms_torque_request_frame_name, @vms_status_frame_name])
  end

  def throttle(percentage_throttle, gear) do
    {max_torque, factor} = case gear do
      "drive" -> {50, 1} #TODO store in DB
      "reverse" -> {20, -1}
      _ -> {0, 0}
    end
    torque = factor * percentage_throttle * max_torque
    :ok = Emitter.update(@network_name, @vms_torque_request_frame_name, fn (emitter_state) ->
      emitter_state |> put_in([:data, "torque"], torque)
    end)
  end

  def rpm() do
    GenServer.call(__MODULE__, :rpm)
  end

  def ready_to_drive?() do
    true # Should check inverter can messages for actual status
  end
end
