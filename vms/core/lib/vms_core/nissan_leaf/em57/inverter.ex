defmodule VmsCore.NissanLeaf.Em57.Inverter do
  use GenServer

  alias VmsCore.NissanLeaf.Util
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @network_name :leaf_drive
  @inverter_status_frame_name "inverter_status"
  @inverter_temperatures_frame_name "inverter_temperatures"
  @vms_alive_frame_name "vms_alive"
  @vms_torque_request_frame_name "vms_torque_request"
  @vms_status_frame_name "vms_status"
  @max_rotation_per_minute 6000 # documented max rpm, on init the inverter is returning very high invalid values
  @zero D.new(0)
  @drive_max_torque D.new(5) # TODO store in DB
  @reverse_max_torque D.new(-5)
  @effective_throttle_threshold D.new("0.05")

  @impl true
  def init(_) do
    :ok = init_emitters()
    Receiver.subscribe(self(), @network_name, [@inverter_status_frame_name, @inverter_temperatures_frame_name])
    {:ok, %{
      rotation_per_minute: 0,
      output_voltage: @zero,
      effective_torque: @zero,
      requested_torque: @zero,
      inverter_communication_board_temperature: @zero,
      insulated_gate_bipolar_transistor_temperature: @zero,
      insulated_gate_bipolar_transistor_board_temperature: @zero,
      motor_temperature: @zero
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

  @impl true
  def handle_call(:rotation_per_minute, _from, state) do
    {:reply, {:ok, state.rotation_per_minute}, state}
  end

  @impl true
  def handle_call(:inverter_state, _from, state) do
    {:reply, {:ok, %{
      rotation_per_minute: state.rotation_per_minute,
      requested_torque: state.requested_torque,
      effective_torque: state.effective_torque,
      output_voltage: state.output_voltage,
      inverter_communication_board_temperature: state.inverter_communication_board_temperature,
      insulated_gate_bipolar_transistor_temperature: state.insulated_gate_bipolar_transistor_temperature,
      insulated_gate_bipolar_transistor_board_temperature: state.insulated_gate_bipolar_transistor_board_temperature,
      motor_temperature: state.motor_temperature
    }}, state}
  end

  @impl true
  def handle_call({:throttle, percentage_throttle, gear}, _from, state) do
    max_torque= case gear do
      "drive"   -> @drive_max_torque
      "reverse" -> @reverse_max_torque
      _         -> @zero
    end
    percentage_throttle = case D.lt?(percentage_throttle, @effective_throttle_threshold)  do
      true  -> @zero
      false -> percentage_throttle
    end
    requested_torque = D.mult(percentage_throttle, max_torque)
    :ok = Emitter.update(@network_name, @vms_torque_request_frame_name, fn (emitter_state) ->
      emitter_state |> put_in([:data, "requested_torque"], requested_torque)
    end)
    {:reply, :ok, %{state | requested_torque: requested_torque}}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: @inverter_status_frame_name, signals: signals}}, state) do
    %{
      "inverter_output_voltage" => %Signal{value: output_voltage},
      "em57_effective_torque" => %Signal{value: effective_torque},
      "em57_rotations_per_minute" => %Signal{value: rotation_per_minute},
    } = signals

    rotation_per_minute = case D.gt?(rotation_per_minute, @max_rotation_per_minute) do
      true  -> @zero
      false -> rotation_per_minute
    end
    {:noreply, %{
      state |
        rotation_per_minute: rotation_per_minute,
        effective_torque: effective_torque,
        output_voltage: output_voltage
      }
    }
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: @inverter_temperatures_frame_name, signals: signals}}, state) do
    %{
      "inverter_communication_board_temperature"            => %Signal{value: inverter_communication_board_temperature},
      "insulated_gate_bipolar_transistor_temperature"       => %Signal{value: insulated_gate_bipolar_transistor_temperature},
      "insulated_gate_bipolar_transistor_board_temperature" => %Signal{value: insulated_gate_bipolar_transistor_board_temperature},
      "motor_temperature"                                   => %Signal{value: motor_temperature}
    } = signals

    {:noreply, %{
      state |
        inverter_communication_board_temperature: inverter_communication_board_temperature,
        insulated_gate_bipolar_transistor_temperature: insulated_gate_bipolar_transistor_temperature,
        insulated_gate_bipolar_transistor_board_temperature: insulated_gate_bipolar_transistor_board_temperature,
        motor_temperature: motor_temperature
      }
    }
  end

  def alive_frame_parameters_builder(emitter_state) do
    {:ok, nil, emitter_state}
  end

  def torque_frame_parameters_builder(emitter_state) do
    counter = emitter_state.data["counter"]
    parameters = %{
      "requested_torque" => emitter_state.data["requested_torque"],
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
    GenServer.call(__MODULE__, {:throttle, percentage_throttle, gear})
  end

  def inverter_state() do
    GenServer.call(__MODULE__, :inverter_state)
  end

  def rotation_per_minute() do
    GenServer.call(__MODULE__, :rotation_per_minute)
  end

  def ready_to_drive?() do
    {:ok, true} # TODO Should check inverter can messages for actual status
  end
end
