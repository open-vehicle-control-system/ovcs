defmodule InfotainmentCore.Vehicles.OVCS1 do
  use GenServer
  require Logger

  alias Cantastic.{Emitter, Receiver, ReceivedFrameWatcher, Frame, Signal}
  alias Decimal, as: D

  @loop_period 10
  @gear_selection_delay 1
  @zero D.new(0)

  @status_frame_names ["vms_status", "front_controller_alive", "controls_controller_alive", "rear_controller_alive"]

  @impl true
  def init(_) do
    :ok = Emitter.configure(:ovcs, "infotainment_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "requested_gear" => "parking",
      },
      enable: true
    })
    :ok = ReceivedFrameWatcher.enable(:ovcs, @status_frame_names)
    :ok = Receiver.subscribe(self(), :ovcs, @status_frame_names ++ [
      "rear_controller_digital_and_analog_pin_status",
      "gear_status",
      "drivetrain_status",
      "passenger_compartment_status",
      "pack_status",
      "twelve_volt_battery_status"
    ])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      requested_gear: "parking",
      selected_gear: "parking",
      last_gear_update_at: Time.utc_now(),
      front_left_door_open: false,
      front_right_door_open: false,
      rear_left_door_open: false,
      rear_right_door_open: false,
      trunk_door_open: false,
      beam_active: false,
      handbrake_engaged: false,
      speed: @zero,
      ready_to_drive: false,
      inverter_enabled: false,
      main_negative_contactor_enabled: false,
      main_positive_contactor_enabled: false,
      precharge_contactor_enabled: false,
      vms_is_alive: false,
      bms_is_alive: false,
      bms_error: false,
      front_controler_is_alive: false,
      controls_controller_is_alive: false,
      rear_controller_is_alive: false,
      vms_status: "MISSING",
      front_controller_status: "MISSING",
      controls_controller_status: "MISSING",
      rear_controller_status: "MISSING",
      vms_computed_status: "MISSING",
      bms_computed_status: "MISSING",
      front_controler_computed_status: "MISSING",
      controls_controller_computed_status: "MISSING",
      rear_controller_computed_status: "MISSING",
      pack_voltage: @zero,
      pack_state_of_charge: @zero,
      pack_average_temperature: @zero,
      pack_is_charging: false,
      pack_current: @zero,
      twelve_volt_battery_status: @zero,
      j1772_plug_state: "disconnected"
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_components_statuses()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "gear_status", signals: signals}}, state) do
    %{"selected_gear" => %Signal{value: selected_gear}} = signals
    state = if selected_gear != state.requested_gear && Time.diff(Time.utc_now(), state.last_gear_update_at) > @gear_selection_delay do
      :ok = Emitter.update(:ovcs, "infotainment_status", fn (data) ->
        %{data | "requested_gear" => selected_gear}
      end)
      %{state | requested_gear: selected_gear}
    else
      state
    end
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info({:handle_frame, %Frame{name: "drivetrain_status", signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    {:noreply, %{state | speed: speed}}
  end

  def handle_info({:handle_frame, %Frame{name: "vms_status", signals: signals}}, state) do
    %{
      "ready_to_drive" => %Signal{value: ready_to_drive},
      "status" => %Signal{value: status}
    } = signals
    {:noreply, %{state |
      ready_to_drive: ready_to_drive,
      vms_status: status
    }}
  end

  def handle_info({:handle_frame, %Frame{name: "front_controller_alive", signals: signals}}, state) do
    %{"status" => %Signal{value: status}} = signals
    {:noreply, %{state | front_controller_status: status}}
  end

  def handle_info({:handle_frame, %Frame{name: "controls_controller_alive", signals: signals}}, state) do
    %{"status" => %Signal{value: status}} = signals
    {:noreply, %{state | controls_controller_status: status}}
  end

  def handle_info({:handle_frame, %Frame{name: "rear_controller_alive", signals: signals}}, state) do
    %{"status" => %Signal{value: status}} = signals
    {:noreply, %{state | rear_controller_status: status}}
  end

  def handle_info({:handle_frame, %Frame{name: "passenger_compartment_status", signals: signals}}, state) do
    %{
      "front_left_door_open" => %Signal{value: front_left_door_open},
      "front_right_door_open" => %Signal{value: front_right_door_open},
      "rear_left_door_open" => %Signal{value: rear_left_door_open},
      "rear_right_door_open" => %Signal{value: rear_right_door_open},
      "trunk_door_open" => %Signal{value: trunk_door_open},
      "beam_active" => %Signal{value: beam_active},
      "handbrake_engaged" => %Signal{value: handbrake_engaged}
    } = signals
    {:noreply, %{state |
        front_left_door_open: front_left_door_open,
        front_right_door_open: front_right_door_open,
        rear_left_door_open: rear_left_door_open,
        rear_right_door_open: rear_right_door_open,
        trunk_door_open: trunk_door_open,
        beam_active: beam_active,
        handbrake_engaged: handbrake_engaged
      }
    }
  end

  def handle_info({:handle_frame, %Frame{name: "rear_controller_digital_and_analog_pin_status", signals: signals}}, state) do
    %{
      "digital_pin3_enabled" => %Signal{value: main_negative_contactor_enabled},
      "digital_pin4_enabled" => %Signal{value: main_positive_contactor_enabled},
      "digital_pin5_enabled" => %Signal{value: precharge_contactor_enabled},
      "digital_pin7_enabled" => %Signal{value: inverter_enabled},
    } = signals

    {:noreply, %{state |
      main_negative_contactor_enabled: main_negative_contactor_enabled,
      main_positive_contactor_enabled: main_positive_contactor_enabled,
      precharge_contactor_enabled: precharge_contactor_enabled,
      inverter_enabled: inverter_enabled
    }}
  end

  def handle_info({:handle_frame, %Frame{name: "pack_status", signals: signals}}, state) do
    %{
      "pack_voltage" => %Signal{value: pack_voltage},
      "pack_state_of_charge" => %Signal{value: pack_state_of_charge},
      "pack_average_temperature" => %Signal{value: pack_average_temperature},
      "is_charging" => %Signal{value: pack_is_charging},
      "pack_current" => %Signal{value: pack_current},
      "j1772_plug_state" => %Signal{value: j1772_plug_state},
      "bms_error" => %Signal{value: bms_error},
      "bms_is_alive" => %Signal{value: bms_is_alive}
    } = signals

    {:noreply, %{state |
      pack_voltage: pack_voltage,
      pack_state_of_charge: pack_state_of_charge,
      pack_average_temperature: pack_average_temperature,
      pack_is_charging: pack_is_charging,
      pack_current: pack_current,
      j1772_plug_state: j1772_plug_state,
      bms_error: bms_error,
      bms_is_alive: bms_is_alive
    }}
  end

  def handle_info({:handle_frame, %Frame{name: "twelve_volt_battery_status", signals: signals}}, state) do
    %{"battery_voltage" => %Signal{value: twelve_volt_battery_status}} = signals
    {:noreply, %{state | twelve_volt_battery_status: twelve_volt_battery_status}}
  end

  defp compute_components_statuses(state) do
    {:ok, vms_is_alive}                 = ReceivedFrameWatcher.is_alive?(:ovcs, "vms_status")
    {:ok, front_controler_is_alive}     = ReceivedFrameWatcher.is_alive?(:ovcs, "front_controller_alive")
    {:ok, controls_controller_is_alive} = ReceivedFrameWatcher.is_alive?(:ovcs, "controls_controller_alive")
    {:ok, rear_controller_is_alive}     = ReceivedFrameWatcher.is_alive?(:ovcs, "rear_controller_alive")

    %{state |
      vms_computed_status: if vms_is_alive do state.vms_status else "MISSING" end,
      bms_computed_status: cond do
        !state.bms_is_alive -> "MISSING"
        state.bms_error -> "FAILURE"
        true -> "OK"
      end,
      front_controler_computed_status: if front_controler_is_alive do state.front_controller_status else "MISSING" end,
      controls_controller_computed_status: if controls_controller_is_alive do state.controls_controller_status else "MISSING" end,
      rear_controller_computed_status: if rear_controller_is_alive do state.rear_controller_status else "MISSING" end,
    }
  end

  @impl true
  def handle_call({:request_gear, gear}, _from, state) do
    :ok = Emitter.update(:ovcs, "infotainment_status", fn (data) ->
      %{data | "requested_gear" => gear}
    end)
    {:reply, {:ok, gear}, %{state | requested_gear: gear, last_gear_update_at: Time.utc_now()}}
  end

  def handle_call(:status, _from, state) do
    status = state |> Map.take([
      :selected_gear,
      :front_left_door_open,
      :front_right_door_open,
      :rear_left_door_open,
      :rear_right_door_open,
      :trunk_door_open,
      :beam_active,
      :handbrake_engaged,
      :speed,
      :ready_to_drive,
      :inverter_enabled,
      :main_negative_contactor_enabled,
      :main_positive_contactor_enabled,
      :precharge_contactor_enabled,
      :vms_computed_status,
      :bms_computed_status,
      :front_controler_computed_status,
      :controls_controller_computed_status,
      :rear_controller_computed_status,
      :rear_controller_computed_status,
      :pack_voltage,
      :pack_state_of_charge,
      :pack_average_temperature,
      :pack_is_charging,
      :pack_current,
      :twelve_volt_battery_status,
      :j1772_plug_state
    ])
    {:reply, {:ok, status}, state}
  end

  def request_gear(gear) do
    GenServer.call(__MODULE__, {:request_gear, gear})
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end
end
