defmodule VmsCore.NissanLeaf.Em57.Inverter do
  use GenServer

  alias VmsCore.NissanLeaf.Util
  alias Cantastic.Emitter

  @network_name :leaf_drive
  @inverter_status_frame_name "inverter_status"

  @impl true
  def init(_) do
    :ok = init_emitters()
    Cantastic.Receiver.subscribe(self(), @network_name, [@inverter_status_frame_name])
    {:ok, %{
      selected_gear: "parking",
      rpm: 0
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, "vms_alive", %{
      parameters_builder_function: &alive_frame_parameters_builder/1,
      initial_data: nil
    })
    :ok = Emitter.configure(@network_name, "vms_torque_request", %{
      parameters_builder_function: &torque_frame_parameters_builder/1,
      initial_data: %{
        "torque" => 0,
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@network_name, "vms_status", %{
      parameters_builder_function: &status_frame_parameters_builder/1,
      initial_data: %{
        "gear" => "parking",
        "counter" => 0
      }
    })
    :ok
  end

  @impl true
  def handle_cast({:select_gear, gear}, state) do
    {:noreply, %{state | selected_gear: gear}}
  end

  @impl true
  def handle_call(:selected_gear, _from, state) do
    {:reply, state.selected_gear, state}
  end

  @impl true
  def handle_call(:rpm, _from, state) do
    {:reply, state.rpm, state}
  end

  @impl true
  def handle_info({:handle_frame,  _frame, [%{value: rpm}] = _signals}, state) do
    {:noreply, %{state | rpm: rpm}}
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
    Emitter.batch_enable(@network_name, ["vms_alive", "vms_torque_request", "vms_status"])
  end

  def off() do
    Emitter.batch_disable(@network_name, ["vms_alive", "vms_torque_request", "vms_status"])
  end

  def throttle(percentage_throttle) do
    torque = case percentage_throttle do
      value when value < 0.3 -> 0
      value when value < 0.6 -> 33
      _                      -> 60
    end
    :ok = Emitter.update(@network_name, "vms_torque_request", fn (state) ->
      state |> put_in([:data, "torque"], torque)
    end)
  end

  def select_gear(gear) do
    :ok = Emitter.update(@network_name, "vms_status", fn (state) ->
      state |> put_in([:data, "gear"], gear)
    end)
    GenServer.cast(__MODULE__, {:select_gear, gear}) #TODO check how to receive that info from the inverter itself
  end

  def selected_gear() do
    GenServer.call(__MODULE__, :selected_gear)
  end

  def rpm() do
    GenServer.call(__MODULE__, :rpm)
  end

  def ready_to_drive?() do
    true # Should check inverter can messages for actual status
  end
end
