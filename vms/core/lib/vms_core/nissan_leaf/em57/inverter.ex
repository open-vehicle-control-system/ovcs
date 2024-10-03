defmodule VmsCore.NissanLeaf.Em57.Inverter do
  use GenServer

  alias VmsCore.NissanLeaf.Util
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D
  alias VmsCore.Bus

  @network_name :leaf_drive
  @inverter_status_frame_name "inverter_status"
  @inverter_temperatures_frame_name "inverter_temperatures"
  @vms_alive_frame_name "vms_alive"
  @vms_torque_request_frame_name "vms_torque_request"
  @vms_status_frame_name "vms_status"
  @max_rotation_per_minute 10000
  @zero D.new(0)
  @one D.new(1)
  @drive_max_torque D.new(100) # TODO store in DB
  @reverse_max_torque D.new(-100)
  @effective_throttle_threshold D.new("0.05")
  @motor_max_power D.new("80")
  @motor_max_torque D.new("250")

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    requested_throttle_source: requested_throttle_source,
    selected_gear_source: selected_gear_source,
    contact_source: contact_source,
    controller: controller,
    power_relay_pin: power_relay_pin})
  do
    :ok = init_emitters()
    Receiver.subscribe(self(), @network_name, [@inverter_status_frame_name, @inverter_temperatures_frame_name])
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      rotation_per_minute: 0,
      output_voltage: @zero,
      effective_torque: @zero,
      requested_torque: @zero,
      inverter_communication_board_temperature: @zero,
      insulated_gate_bipolar_transistor_temperature: @zero,
      insulated_gate_bipolar_transistor_board_temperature: @zero,
      motor_temperature: @zero,
      requested_throttle_source: requested_throttle_source,
      selected_gear_source: selected_gear_source,
      contact_source: contact_source,
      requested_throttle: @zero,
      selected_gear: "parking",
      contact: :off,
      loop_timer: timer,
      enabled: false,
      controller: controller,
      power_relay_pin: power_relay_pin
    }}
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, @vms_alive_frame_name, %{
      parameters_builder_function: :default,
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

  def handle_info(%VmsCore.Bus.Message{name: :requested_throttle, value: requested_throttle, source: source}, state) when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%VmsCore.Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state) when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info(%VmsCore.Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_inverter()
      |> apply_torque()
      |> emit_metrics()

    {:noreply, state}
  end

  defp toggle_inverter(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        :ok = Emitter.enable(@network_name, [@vms_alive_frame_name, @vms_torque_request_frame_name, @vms_status_frame_name])
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        %{state | enabled: true}
      {true, :off} ->
        :ok = Emitter.disable(@network_name, [@vms_alive_frame_name, @vms_torque_request_frame_name, @vms_status_frame_name])
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end

  defp apply_torque(state) do
    max_torque = case state.selected_gear do
      "drive"   -> @drive_max_torque
      "reverse" -> @reverse_max_torque
      _         -> @zero
    end
    requested_throttle = case D.lt?(state.requested_throttle, @effective_throttle_threshold)  do
      true  -> @zero
      false -> state.requested_throttle
    end
    requested_torque = D.mult(requested_throttle, max_torque)

    :ok = Emitter.update(@network_name, @vms_torque_request_frame_name, fn (data) ->
      %{data | "requested_torque" => requested_torque}
    end)

    %{state | requested_torque: requested_torque}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :effective_torque, value: state.effective_torque, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :output_voltage, value: state.output_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :inverter_communication_board_temperature, value: state.inverter_communication_board_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :insulated_gate_bipolar_transistor_temperature, value: state.insulated_gate_bipolar_transistor_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :insulated_gate_bipolar_transistor_board_temperature, value: state.insulated_gate_bipolar_transistor_board_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :motor_temperature, value: state.motor_temperature, source: __MODULE__})
    state
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @inverter_status_frame_name, signals: signals}}, state) do
    %{
      "inverter_output_voltage" => %Signal{value: output_voltage},
      "em57_effective_torque" => %Signal{value: effective_torque},
      "em57_rotations_per_minute" => %Signal{value: rotation_per_minute},
    } = signals
    rotation_per_minute = abs(rotation_per_minute)
    {:noreply, %{
      state |
        rotation_per_minute: rotation_per_minute,
        effective_torque: effective_torque,
        output_voltage: output_voltage
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @inverter_temperatures_frame_name, signals: signals}}, state) do
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

  def torque_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "requested_torque" => data["requested_torque"],
      "counter" => Util.shifted_counter(counter),
      "crc" => &Util.crc8/1
    }

    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
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
