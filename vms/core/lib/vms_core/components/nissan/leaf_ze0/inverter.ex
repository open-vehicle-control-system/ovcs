defmodule VmsCore.Components.Nissan.LeafZE0.Inverter do
  @moduledoc """
    Nissan Leaf ZE0/EM57 Inverter
  """
  use GenServer

  alias Cantastic.{Emitter,  Frame, Receiver, Signal}
  alias Decimal, as: D
  alias VmsCore.{
    Bus,
    Components.Nissan.Util,
    Components.OVCS.GenericController
  }

  @zero D.new(0)
  #@motor_max_torque D.new("250")
  #@motor_max_power D.new("80")
  @max_torque 100
  @drive_max_torque D.new(@max_torque) # TODO store in DB
  @reverse_max_torque D.new(-@max_torque)
  @effective_throttle_threshold D.new("0.05")

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
    :ok = Emitter.configure(:leaf_drive, "vms_alive", %{
      parameters_builder_function: :default,
      initial_data: nil
    })
    :ok = Emitter.configure(:leaf_drive, "vms_torque_request", %{
      parameters_builder_function: &torque_frame_parameters_builder/1,
      initial_data: %{
        "requested_torque" => @zero,
        "counter" => 0
      }
    })
    :ok = Emitter.configure(:leaf_drive, "vms_status", %{
      parameters_builder_function: &status_frame_parameters_builder/1,
      initial_data: %{
        "gear" => "drive",
        "counter" => 0
      }
    })
    Receiver.subscribe(self(), :leaf_drive, ["inverter_status", "inverter_temperatures"])
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      rotation_per_minute: 0,
      inverter_output_voltage: 0,
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
      selected_gear: :parking,
      contact: :off,
      loop_timer: timer,
      enabled: false,
      controller: controller,
      power_relay_pin: power_relay_pin,
      ready_to_drive: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_inverter()
      |> apply_torque()
      |> check_ready_to_drive()
      |> emit_metrics()

    {:noreply, state}
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

  def handle_info({:handle_frame, %Frame{name: "inverter_status", signals: signals}}, state) do
    %{
      "inverter_output_voltage" => %Signal{value: inverter_output_voltage},
      "effective_torque"        => %Signal{value: effective_torque},
      "rotations_per_minute"    => %Signal{value: rotation_per_minute},
    } = signals
    rotation_per_minute = abs(rotation_per_minute)
    {:noreply, %{
      state |
        rotation_per_minute: rotation_per_minute,
        effective_torque: effective_torque,
        inverter_output_voltage: inverter_output_voltage
      }
    }
  end
  def handle_info({:handle_frame, %Frame{name: "inverter_temperatures", signals: signals}}, state) do
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

  defp toggle_inverter(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        :ok = Emitter.enable(:leaf_drive, ["vms_alive", "vms_torque_request", "vms_status"])
        %{state | enabled: true}
      {true, :off} ->
        :ok = Emitter.disable(:leaf_drive, ["vms_alive", "vms_torque_request", "vms_status"])
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end

  defp apply_torque(state) do
    max_torque = case state.selected_gear do
      :drive   -> @drive_max_torque
      :reverse -> @reverse_max_torque
      _         -> @zero
    end
    requested_throttle = case D.lt?(state.requested_throttle, @effective_throttle_threshold)  do
      true  -> @zero
      false -> state.requested_throttle
    end
    requested_torque = D.mult(requested_throttle, max_torque)

    :ok = Emitter.update(:leaf_drive, "vms_torque_request", fn (data) ->
      %{data | "requested_torque" => requested_torque}
    end)

    %{state | requested_torque: requested_torque}
  end

  defp check_ready_to_drive(state) do
    {:ok, power_relay_enabled} = GenericController.get_digital_value(state.controller, state.power_relay_pin)
    %{state | ready_to_drive: power_relay_enabled && state.enabled}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_torque, value: state.requested_torque, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :effective_torque, value: state.effective_torque, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :inverter_output_voltage, value: state.inverter_output_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :inverter_communication_board_temperature, value: state.inverter_communication_board_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :insulated_gate_bipolar_transistor_temperature, value: state.insulated_gate_bipolar_transistor_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :insulated_gate_bipolar_transistor_board_temperature, value: state.insulated_gate_bipolar_transistor_board_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :motor_temperature, value: state.motor_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    state
  end

  defp torque_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "requested_torque" => data["requested_torque"],
      "counter" => Util.shifted_counter(counter),
      "crc" => &Util.crc8/1
    }

    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end

  defp status_frame_parameters_builder(data) do
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
