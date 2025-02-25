defmodule VmsCore.Components.Orion.Bms2 do
  @moduledoc """
    Orion BMS
  """
  use GenServer
  alias VmsCore.Bus

  require Logger
  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)

  @impl true
  def init(%{ac_input_voltage_source: ac_input_voltage_source}) do
    :ok = Emitter.configure(:orion_bms, "bms_command", %{
      parameters_builder_function: :default,
      initial_data: %{
        "ac_input_voltage" => 0
      },
      enable: true
    })
    Bus.subscribe("messages")
    :ok = Receiver.subscribe(self(), :orion_bms, ["bms_status_1", "bms_status_2"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      pack_current: @zero,
      pack_instant_voltage: @zero,
      discharge_relay_enabled: nil,
      charge_relay_enabled: nil,
      charger_safety_relay_enabled: nil,
      malfunction_relay_enabled: nil,
      multipurpose_input_1_enabled: nil,
      always_on_status_enabled: nil,
      is_ready_status_enabled: nil,
      is_charging_status_enabled: nil,
      multipurpose_input_2_enabled: nil,
      multipurpose_input_3_enabled: nil,
      multipurpose_output_2_enabled: nil,
      multipurpose_output_3_enabled: nil,
      multipurpose_output_4_enabled: nil,
      multipurpose_enable_status_enabled: nil,
      multipurpose_output_1_enabled: nil,
      charge_interlock_enabled: nil,
      current_failsafe_enabled: nil,
      voltage_failsafe_enabled: nil,
      input_power_supply_failsafe_enabled: nil,
      charge_max_power: @zero,
      discharge_max_power: nil,
      adaptative_state_of_charge: nil,
      state_of_health: nil,
      output_power: nil,
      ac_input_voltage_source: ac_input_voltage_source,
      ac_input_voltage: 0,
      emitted_ac_input_voltage: 0
    }}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end


  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_ac_input_voltage()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :ac_voltage, value: ac_voltage, source: source}, state) when source == state.ac_input_voltage_source do
    {:noreply, %{state | ac_input_voltage: ac_voltage}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "bms_status_1", signals: signals}}, state) do
    %{
      "pack_current" => %Signal{value: pack_current},
      "pack_instant_voltage" => %Signal{value: pack_instant_voltage},
      # "discharge_relay_enabled" => %Signal{value: discharge_relay_enabled},
      # "charge_relay_enabled" => %Signal{value: charge_relay_enabled},
      # "charger_safety_relay_enabled" => %Signal{value: charger_safety_relay_enabled},
      # "malfunction_relay_enabled" => %Signal{value: malfunction_relay_enabled},
      # "multipurpose_input_1_enabled" => %Signal{value: multipurpose_input_1_enabled},
      # "always_on_status_enabled" => %Signal{value: always_on_status_enabled},
      # "is_ready_status_enabled" => %Signal{value: is_ready_status_enabled},
      # "is_charging_status_enabled" => %Signal{value: is_charging_status_enabled},
      # "multipurpose_input_2_enabled" => %Signal{value: multipurpose_input_2_enabled},
      # "multipurpose_input_3_enabled" => %Signal{value: multipurpose_input_3_enabled},
      # "multipurpose_output_2_enabled" => %Signal{value: multipurpose_output_2_enabled},
      # "multipurpose_output_3_enabled" => %Signal{value: multipurpose_output_3_enabled},
      # "multipurpose_output_4_enabled" => %Signal{value: multipurpose_output_4_enabled},
      # "multipurpose_enable_status_enabled" => %Signal{value: multipurpose_enable_status_enabled},
      # "multipurpose_output_1_enabled" => %Signal{value: multipurpose_output_1_enabled},
      # "charge_interlock_enabled" => %Signal{value: charge_interlock_enabled},
      # "current_failsafe_enabled" => %Signal{value: current_failsafe_enabled},
      # "voltage_failsafe_enabled" => %Signal{value: voltage_failsafe_enabled},
      # "input_power_supply_failsafe_enabled" => %Signal{value: input_power_supply_failsafe_enabled}
    } = signals
    {:noreply, %{state |
      pack_current: pack_current,
      pack_instant_voltage: pack_instant_voltage,
      # discharge_relay_enabled: discharge_relay_enabled,
      # charge_relay_enabled: charge_relay_enabled,
      # charger_safety_relay_enabled: charger_safety_relay_enabled,
      # malfunction_relay_enabled: malfunction_relay_enabled,
      # multipurpose_input_1_enabled: multipurpose_input_1_enabled,
      # always_on_status_enabled: always_on_status_enabled,
      # is_ready_status_enabled: is_ready_status_enabled,
      # is_charging_status_enabled: is_charging_status_enabled,
      # multipurpose_input_2_enabled: multipurpose_input_2_enabled,
      # multipurpose_input_3_enabled: multipurpose_input_3_enabled,
      # multipurpose_output_2_enabled: multipurpose_output_2_enabled,
      # multipurpose_output_3_enabled: multipurpose_output_3_enabled,
      # multipurpose_output_4_enabled: multipurpose_output_4_enabled,
      # multipurpose_enable_status_enabled: multipurpose_enable_status_enabled,
      # multipurpose_output_1_enabled: multipurpose_output_1_enabled,
      # charge_interlock_enabled: charge_interlock_enabled,
      # current_failsafe_enabled: current_failsafe_enabled,
      # voltage_failsafe_enabled: voltage_failsafe_enabled,
      # input_power_supply_failsafe_enabled: input_power_supply_failsafe_enabled
    }}
  end
  def handle_info({:handle_frame,  %Frame{name: "bms_status_2", signals: signals}}, state) do
    %{
      "charge_max_power" => %Signal{value: charge_max_power},
      # "discharge_max_power" => %Signal{value: discharge_max_power},
      # "adaptative_state_of_charge" => %Signal{value: adaptative_state_of_charge},
      # "state_of_health" => %Signal{value: state_of_health},
      # "output_power" => %Signal{value: output_power},
    } = signals
    {:noreply, %{state |
      charge_max_power: charge_max_power,
      # discharge_max_power: discharge_max_power,
      # adaptative_state_of_charge: adaptative_state_of_charge,
      # state_of_health: state_of_health,
      # output_power: output_power
    }}
  end

  defp handle_ac_input_voltage(state) do
    case state.ac_input_voltage != state.emitted_ac_input_voltage do
      true ->
        :ok = Emitter.update(:orion_bms, "bms_command", fn (data) ->
          %{data | "ac_input_voltage" => state.ac_input_voltage}
        end)
        %{state | emitted_ac_input_voltage: state.ac_input_voltage}
      _ ->
        state
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :maximum_power_for_charger, value: state.charge_max_power, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_current, value: state.pack_current, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :pack_instant_voltage, value: state.pack_instant_voltage, source: __MODULE__})
    state
  end
end
