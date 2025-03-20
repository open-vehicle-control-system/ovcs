defmodule VmsCore.Components.Orion.Bms2 do
  @moduledoc """
    Orion BMS
  """
  use GenServer
  alias VmsCore.Bus

  require Logger
  alias Cantastic.{Frame, Receiver, Signal}
  alias Decimal, as: D

  @zero D.new(0)
  @loop_period 10

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :orion_bms, ["bms_status_1", "bms_status_2", "bms_status_3"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      pack_current: @zero,
      pack_voltage: @zero,
      pack_state_of_charge: @zero,
      j1772_plug_state: "disconnected",
      twelve_volt_battery_voltage: @zero,
      pack_lowest_temperature: @zero,
      pack_highest_temperature: @zero,
      pack_average_temperature: @zero,
      is_charging_source_enabled: false,
      is_ready_source_enabled: false,
      charger_safety_relay_enabled: false,
      discharge_relay_enabled: false,
      charge_interlock_enabled: false,
      balancing_active: false,
      bms_error: false
    }}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit_metrics()
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "bms_status_1", signals: signals}}, state) do
    %{
      "pack_current" => %Signal{value: pack_current},
      "pack_voltage" => %Signal{value: pack_voltage},
      "pack_adaptative_state_of_charge" => %Signal{value: pack_adaptative_state_of_charge},
      "j1772_plug_state" => %Signal{value: j1772_plug_state}
    } = signals
    {:noreply, %{state |
      pack_current: pack_current,
      pack_voltage: pack_voltage,
      pack_state_of_charge: pack_adaptative_state_of_charge,
      j1772_plug_state: j1772_plug_state
    }}
  end
  def handle_info({:handle_frame,  %Frame{name: "bms_status_2", signals: signals}}, state) do
    %{
      "twelve_volt_battery_voltage" => %Signal{value: twelve_volt_battery_voltage},
      "pack_lowest_temperature" => %Signal{value: pack_lowest_temperature},
      "pack_highest_temperature" => %Signal{value: pack_highest_temperature},
      "pack_average_temperature" => %Signal{value: pack_average_temperature}
    } = signals
    {:noreply, %{state |
      twelve_volt_battery_voltage: twelve_volt_battery_voltage,
      pack_lowest_temperature: pack_lowest_temperature,
      pack_highest_temperature: pack_highest_temperature,
      pack_average_temperature: pack_average_temperature
    }}
  end
  def handle_info({:handle_frame,  %Frame{name: "bms_status_3", signals: signals}}, state) do
    %{
      "is_charging_source_enabled" => %Signal{value: is_charging_source_enabled},
      "is_ready_source_enabled" => %Signal{value: is_ready_source_enabled},
      "charger_safety_relay_enabled" => %Signal{value: charger_safety_relay_enabled},
      "discharge_relay_enabled" => %Signal{value: discharge_relay_enabled},
      "charge_interlock_enabled" => %Signal{value: charge_interlock_enabled},
      "balancing_active" => %Signal{value: balancing_active},
      "malfunction_indicator_active" => %Signal{value: bms_error}
    } = signals
    {:noreply, %{state |
      is_charging_source_enabled: is_charging_source_enabled,
      is_ready_source_enabled: is_ready_source_enabled,
      charger_safety_relay_enabled: charger_safety_relay_enabled,
      discharge_relay_enabled: discharge_relay_enabled,
      charge_interlock_enabled: charge_interlock_enabled,
      balancing_active: balancing_active,
      bms_error: bms_error
    }}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :pack_current, value: state.pack_current, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_voltage, value: state.pack_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_state_of_charge, value: state.pack_state_of_charge, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :j1772_plug_state, value: state.j1772_plug_state, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :twelve_volt_battery_voltage, value: state.twelve_volt_battery_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_lowest_temperature, value: state.pack_lowest_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_highest_temperature, value: state.pack_highest_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_average_temperature, value: state.pack_average_temperature, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :is_charging_source_enabled, value: state.is_charging_source_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :is_ready_source_enabled, value: state.is_ready_source_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :charger_safety_relay_enabled, value: state.charger_safety_relay_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :discharge_relay_enabled, value: state.discharge_relay_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :charge_interlock_enabled, value: state.charge_interlock_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :balancing_active, value: state.balancing_active, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :bms_error, value: state.bms_error, source: __MODULE__})
    state
  end
end
