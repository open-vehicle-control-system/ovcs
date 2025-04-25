defmodule VmsCore.Components.OVCS.Status do
  @moduledoc """
    OVCS Status module emitting metrics in the OVCS format
  """
  use GenServer
  alias VmsCore.Bus
  alias Cantastic.{Emitter}
  alias Decimal, as: D

  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{bms_status_source: bms_status_source}) do
    :ok = Emitter.configure(:ovcs, "pack_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "pack_current" => @zero,
        "pack_voltage" => @zero,
        "pack_state_of_charge" => @zero,
        "pack_average_temperature" => @zero,
        "is_charging" => false,
        "charge_interlock_enabled" => false,
        "balancing_active" => false,
        "bms_error" => false,
        "bms_is_alive" => false,
        "j1772_plug_state" => "disconnected"
      },
      enable: true
    })
    :ok = Emitter.configure(:ovcs, "twelve_volt_battery_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "battery_voltage" => @zero,
      },
      enable: true
    })
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      bms_status_source: bms_status_source,
      pack_current: @zero,
      pack_voltage: @zero,
      pack_state_of_charge: @zero,
      pack_average_temperature: @zero,
      is_charging: false,
      charge_interlock_enabled: false,
      balancing_active: false,
      bms_error: false,
      bms_is_alive: false,
      j1772_plug_state: "disconnected",
      twelve_volt_battery_voltage: @zero,
      pack_status_frame_requires_update: false,
      charger_safety_relay_enabled: false,
      twelve_volt_battery_status_frame_requires_update: true
    }}
end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_pack_status()
      |> handle_twelve_volt_battery_status_status()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :pack_current, value: pack_current, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      pack_current: pack_current,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || pack_current != state.pack_current
    }}
  end
  def handle_info(%Bus.Message{name: :pack_voltage, value: pack_voltage, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      pack_voltage: pack_voltage,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || pack_voltage != state.pack_voltage
    }}
  end
  def handle_info(%Bus.Message{name: :pack_state_of_charge, value: pack_state_of_charge, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      pack_state_of_charge: pack_state_of_charge,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || pack_state_of_charge != state.pack_state_of_charge
    }}
  end
  def handle_info(%Bus.Message{name: :j1772_plug_state, value: j1772_plug_state, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      j1772_plug_state: j1772_plug_state,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || j1772_plug_state != state.j1772_plug_state
    }}
  end
  def handle_info(%Bus.Message{name: :pack_average_temperature, value: pack_average_temperature, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      pack_average_temperature: pack_average_temperature,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || pack_average_temperature != state.pack_average_temperature
    }}
  end
  def handle_info(%Bus.Message{name: :charge_interlock_enabled, value: charge_interlock_enabled, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      charge_interlock_enabled: charge_interlock_enabled,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || charge_interlock_enabled != state.charge_interlock_enabled
    }}
  end
  def handle_info(%Bus.Message{name: :balancing_active, value: balancing_active, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      balancing_active: balancing_active,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || balancing_active != state.balancing_active
    }}
  end
  def handle_info(%Bus.Message{name: :charger_safety_relay_enabled, value: charger_safety_relay_enabled, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      charger_safety_relay_enabled: charger_safety_relay_enabled,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || charger_safety_relay_enabled != state.charger_safety_relay_enabled
    }}
  end
  def handle_info(%Bus.Message{name: :bms_error, value: bms_error, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      bms_error: bms_error,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || bms_error != state.bms_error
    }}
  end
  def handle_info(%Bus.Message{name: :is_alive, value: bms_is_alive, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      bms_is_alive: bms_is_alive,
      pack_status_frame_requires_update: state.pack_status_frame_requires_update || bms_is_alive != state.bms_is_alive
    }}
  end
  def handle_info(%Bus.Message{name: :twelve_volt_battery_voltage, value: twelve_volt_battery_voltage, source: source}, state) when source == state.bms_status_source do
    {:noreply, %{state |
      twelve_volt_battery_voltage: twelve_volt_battery_voltage,
      twelve_volt_battery_status_frame_requires_update: state.twelve_volt_battery_status_frame_requires_update || twelve_volt_battery_voltage != state.twelve_volt_battery_voltage
    }}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp handle_pack_status(state) do
    case state.pack_status_frame_requires_update do
      true ->
        :ok = Emitter.update(:ovcs, "pack_status", fn (data) ->
          %{data |
            "pack_current" => state.pack_current,
            "pack_voltage" => state.pack_voltage,
            "pack_state_of_charge" => state.pack_state_of_charge,
            "pack_average_temperature" => state.pack_average_temperature,
            "is_charging" => state.charger_safety_relay_enabled && D.lt?(state.pack_current, @zero),
            "charge_interlock_enabled" => state.charge_interlock_enabled,
            "balancing_active" => state.balancing_active,
            "bms_is_alive" => state.bms_is_alive,
            "bms_error" => state.bms_error,
            "j1772_plug_state" => state.j1772_plug_state
          }
        end)
        %{state | pack_status_frame_requires_update: false}
      _ ->
        state
    end
  end

  defp handle_twelve_volt_battery_status_status(state) do
    case state.twelve_volt_battery_status_frame_requires_update do
      true ->
        :ok = Emitter.update(:ovcs, "twelve_volt_battery_status", fn (data) ->
          %{data |
            "battery_voltage" => state.twelve_volt_battery_voltage,
          }
        end)
        %{state | twelve_volt_battery_status_frame_requires_update: false}
      _ ->
        state
    end
  end
end
