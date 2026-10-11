defmodule VmsCore.Components.Nissan.LeafAZE0.Inverter do
  @moduledoc """
  A Nissan Leaf AZE0 inverter driving an EM57 motor, on the CAN network
  named by `:network`.

  While the contact is on, a generic controller's relay powers the
  inverter and the VMS frames it expects are emitted. Each tick turns the
  selected source's throttle request into a torque request, signed by the
  selected gear and zero outside `:drive` and `:reverse`. Publishes the
  motor rpm (unsigned, and `nil` above the EM57's rated 10,500, where
  the reading is invalid), requested and effective torque, output
  voltage, the inverter and motor temperatures, and `:ready_to_drive`.

  ## Options

    * `:network` — the CAN network it sits on, as named in the vehicle's
      CAN topology.
    * `:selected_control_level_source` — the manager that names the
      throttle source.
    * `:selected_gear_source` — the manager publishing `:selected_gear`.
    * `:contact_source` — the component publishing `:contact`.
    * `:controller`, `:power_relay_pin` — the generic controller digital
      pin switching the inverter's power.
    * `:drive_max_torque_nm`, `:reverse_max_torque_nm` — the torque
      request of a full throttle in `:drive` and in `:reverse`, both
      positive; the reverse request is sent negated.
    * `:effective_throttle_threshold` — requests below it are zero,
      default 0.05.
  """
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.{Nissan.FrameIntegrity, OVCS.GenericController}

  @zero D.new(0)
  # The EM57's rated maximum; the inverter reports higher, invalid values at start.
  @max_valid_rotation_per_minute 10_500
  @default_effective_throttle_threshold D.new("0.05")

  @loop_period_ms 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(
        %{
          network: network,
          selected_control_level_source: selected_control_level_source,
          selected_gear_source: selected_gear_source,
          contact_source: contact_source,
          controller: controller,
          power_relay_pin: power_relay_pin,
          drive_max_torque_nm: drive_max_torque_nm,
          reverse_max_torque_nm: reverse_max_torque_nm
        } = args
      ) do
    :ok =
      Emitter.configure(network, "vms_alive", %{
        parameters_builder_function: :default,
        initial_data: nil
      })

    :ok =
      Emitter.configure(network, "vms_torque_request", %{
        parameters_builder_function: &torque_frame_parameters_builder/1,
        initial_data: %{
          "requested_torque" => @zero,
          "counter" => 0
        }
      })

    :ok =
      Emitter.configure(network, "vms_status", %{
        parameters_builder_function: &status_frame_parameters_builder/1,
        initial_data: %{
          "gear" => "drive",
          "counter" => 0
        }
      })

    Receiver.subscribe(self(), network, ["inverter_status", "inverter_temperatures"])
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       network: network,
       rotation_per_minute: 0,
       inverter_output_voltage: 0,
       effective_torque: @zero,
       requested_torque: @zero,
       inverter_communication_board_temperature: @zero,
       insulated_gate_bipolar_transistor_temperature: @zero,
       insulated_gate_bipolar_transistor_board_temperature: @zero,
       motor_temperature: @zero,
       selected_control_level_source: selected_control_level_source,
       requested_throttle_source: nil,
       selected_gear_source: selected_gear_source,
       contact_source: contact_source,
       requested_throttle: @zero,
       selected_gear: :parking,
       contact: :off,
       loop_timer: timer,
       enabled: false,
       controller: controller,
       power_relay_pin: power_relay_pin,
       drive_max_torque_nm: D.new(drive_max_torque_nm),
       reverse_max_torque_nm: D.new(reverse_max_torque_nm),
       effective_throttle_threshold:
         D.new(
           Map.get(args, :effective_throttle_threshold, @default_effective_throttle_threshold)
         ),
       ready_to_drive: false
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_inverter()
      |> apply_torque()
      |> check_ready_to_drive()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_throttle_source,
          value: requested_throttle_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing: with no source
    # no request message matches, and the last request would be held.
    requested_throttle =
      if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle

    {:noreply,
     %{
       state
       | requested_throttle_source: requested_throttle_source,
         requested_throttle: requested_throttle
     }}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state)
      when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state)
      when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "inverter_status", signals: signals}}, state) do
    %{
      "inverter_output_voltage" => %Signal{value: inverter_output_voltage},
      "effective_torque" => %Signal{value: effective_torque},
      "rotations_per_minute" => %Signal{value: rotation_per_minute}
    } = signals

    rotation_per_minute = valid_rotation_per_minute(abs(rotation_per_minute))

    {:noreply,
     %{
       state
       | rotation_per_minute: rotation_per_minute,
         effective_torque: effective_torque,
         inverter_output_voltage: inverter_output_voltage
     }}
  end

  def handle_info({:handle_frame, %Frame{name: "inverter_temperatures", signals: signals}}, state) do
    %{
      "inverter_communication_board_temperature" => %Signal{
        value: inverter_communication_board_temperature
      },
      "insulated_gate_bipolar_transistor_temperature" => %Signal{
        value: insulated_gate_bipolar_transistor_temperature
      },
      "insulated_gate_bipolar_transistor_board_temperature" => %Signal{
        value: insulated_gate_bipolar_transistor_board_temperature
      },
      "motor_temperature" => %Signal{value: motor_temperature}
    } = signals

    {:noreply,
     %{
       state
       | inverter_communication_board_temperature:
           fahrenheit_to_celsius(inverter_communication_board_temperature),
         insulated_gate_bipolar_transistor_temperature:
           fahrenheit_to_celsius(insulated_gate_bipolar_transistor_temperature),
         insulated_gate_bipolar_transistor_board_temperature:
           fahrenheit_to_celsius(insulated_gate_bipolar_transistor_board_temperature),
         motor_temperature: fahrenheit_to_celsius(motor_temperature)
     }}
  end

  defp toggle_inverter(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        :ok = Emitter.enable(state.network, ["vms_alive", "vms_torque_request", "vms_status"])
        %{state | enabled: true}

      {true, :off} ->
        :ok = Emitter.disable(state.network, ["vms_alive", "vms_torque_request", "vms_status"])
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}

      _ ->
        state
    end
  end

  defp apply_torque(state) do
    max_torque =
      case state.selected_gear do
        :drive -> state.drive_max_torque_nm
        :reverse -> D.negate(state.reverse_max_torque_nm)
        _ -> @zero
      end

    requested_throttle =
      case D.lt?(state.requested_throttle, state.effective_throttle_threshold) do
        true -> @zero
        false -> state.requested_throttle
      end

    requested_torque = D.mult(requested_throttle, max_torque)

    :ok =
      Emitter.update(state.network, "vms_torque_request", fn emitter_data ->
        %{emitter_data | "requested_torque" => requested_torque}
      end)

    %{state | requested_torque: requested_torque}
  end

  defp check_ready_to_drive(state) do
    {:ok, power_relay_enabled} =
      GenericController.get_digital_value(state.controller, state.power_relay_pin)

    %{state | ready_to_drive: power_relay_enabled && state.enabled}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: state.rotation_per_minute,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_torque,
      value: state.requested_torque,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :effective_torque,
      value: state.effective_torque,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :inverter_output_voltage,
      value: state.inverter_output_voltage,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :inverter_communication_board_temperature,
      value: state.inverter_communication_board_temperature,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :insulated_gate_bipolar_transistor_temperature,
      value: state.insulated_gate_bipolar_transistor_temperature,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :insulated_gate_bipolar_transistor_board_temperature,
      value: state.insulated_gate_bipolar_transistor_board_temperature,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :motor_temperature,
      value: state.motor_temperature,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :ready_to_drive,
      value: state.ready_to_drive,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle_source,
      value: state.requested_throttle_source,
      source: __MODULE__
    })

    state
  end

  defp torque_frame_parameters_builder(emitter_data) do
    counter = emitter_data["counter"]

    parameters = %{
      "requested_torque" => emitter_data["requested_torque"],
      "counter" => FrameIntegrity.shifted_counter(counter),
      "crc" => &FrameIntegrity.crc8/1
    }

    emitter_data = %{emitter_data | "counter" => FrameIntegrity.counter(counter + 1)}
    {:ok, parameters, emitter_data}
  end

  defp status_frame_parameters_builder(emitter_data) do
    counter = emitter_data["counter"]

    heartbeat =
      case FrameIntegrity.counter(counter) do
        0 -> 0
        1 -> 1
        2 -> 1
        3 -> 0
      end

    parameters = %{
      "gear" => emitter_data["gear"],
      "heartbeat" => heartbeat,
      "heartbeat1" => FrameIntegrity.counter(counter),
      "counter" => FrameIntegrity.counter(counter),
      "crc" => &FrameIntegrity.crc8/1
    }

    emitter_data = %{emitter_data | "counter" => FrameIntegrity.counter(counter + 1)}
    {:ok, parameters, emitter_data}
  end

  defp valid_rotation_per_minute(rotation_per_minute)
       when rotation_per_minute > @max_valid_rotation_per_minute,
       do: nil

  defp valid_rotation_per_minute(rotation_per_minute), do: rotation_per_minute

  defp fahrenheit_to_celsius(fahrenheit) do
    D.div(fahrenheit - 32, D.new("1.8")) |> D.round()
  end
end
