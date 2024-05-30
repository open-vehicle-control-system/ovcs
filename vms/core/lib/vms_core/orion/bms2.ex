defmodule VmsCore.Orion.Bms2 do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @network_name :orion_bms
  @bms_status_1_frame_name "bms_status_1"
  @bms_status_2_frame_name "bms_status_2"
  @bms_command_frame_name "bms_command"
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = init_emitters()
    :ok = Receiver.subscribe(self(), @network_name, [@bms_status_1_frame_name, @bms_status_2_frame_name])
    :ok = Emitter.enable(@network_name, @bms_command_frame_name)
    {:ok, %{
      charge_max_power: @zero,
      discharge_max_power: @zero,
      pack_current: @zero,
      pack_instant_voltage: @zero,
      discharge_relay_enabled: false,
      charge_relay_enabled: false,
      charger_safety_relay_enabled: false,
      malfunction_relay_enabled: false,
      charge_interlock_enabled: false,
      is_ready_status_enabled: false,
      adaptative_state_of_charge: @zero,
      state_of_health: @zero,
      output_power: @zero
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @bms_status_1_frame_name, signals: signals}}, state) do
    %{
      "pack_current"                 => %Signal{value: pack_current},
      "pack_instant_voltage"         => %Signal{value: pack_instant_voltage},
      "discharge_relay_enabled"      => %Signal{value: discharge_relay_enabled},
      "charge_relay_enabled"         => %Signal{value: charge_relay_enabled},
      "charger_safety_relay_enabled" => %Signal{value: charger_safety_relay_enabled},
      "malfunction_relay_enabled"    => %Signal{value: malfunction_relay_enabled},
      "charge_interlock_enabled"     => %Signal{value: charge_interlock_enabled},
      "is_ready_status_enabled"     => %Signal{value: is_ready_status_enabled}
    } = signals
    {:noreply, %{
      state |
      pack_current: pack_current,
      pack_instant_voltage: pack_instant_voltage,
      discharge_relay_enabled: discharge_relay_enabled,
      charge_relay_enabled: charge_relay_enabled,
      charger_safety_relay_enabled: charger_safety_relay_enabled,
      malfunction_relay_enabled: malfunction_relay_enabled,
      charge_interlock_enabled: charge_interlock_enabled,
      is_ready_status_enabled: is_ready_status_enabled
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @bms_status_2_frame_name, signals: signals}}, state) do
    %{
      "charge_max_power"           => %Signal{value: charge_max_power},
      "discharge_max_power"        => %Signal{value: discharge_max_power},
      "adaptative_state_of_charge" => %Signal{value: adaptative_state_of_charge},
      "state_of_health"            => %Signal{value: state_of_health},
      "output_power"               => %Signal{value: output_power},
    } = signals
    {:noreply, %{
      state |
        charge_max_power: charge_max_power,
        discharge_max_power: discharge_max_power,
        adaptative_state_of_charge: adaptative_state_of_charge,
        state_of_health: state_of_health,
        output_power: output_power
      }
    }
  end

  @impl true
  def handle_call(:ready_to_drive?, _from, state) do
    {:reply, {:ok, !state.charge_interlock_enabled && state.is_ready_status_enabled}, state}
  end

  @impl true
  def handle_call(:allowed_power, _from, state) do
    {:reply, {:ok, state.charge_max_power, state.discharge_max_power}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, @bms_command_frame_name, %{
      parameters_builder_function: &bms_command_frame_parameters_builder/1,
      initial_data: %{
        "ac_input_voltage" => 0
      }
    })
    :ok
  end

  def bms_command_frame_parameters_builder(data) do
    parameters = %{
      "ac_input_voltage" => data["ac_input_voltage"]
    }
    {:ok, parameters, data}
  end

  def ready_to_drive?() do
    GenServer.call(__MODULE__, :ready_to_drive?)
  end

  def allowed_power() do
    GenServer.call(__MODULE__, :allowed_power)
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def ac_input_voltage(ac_input_voltage) do
    :ok = Emitter.update(@network_name, @bms_command_frame_name, fn (data) ->
      %{data | "ac_input_voltage" => ac_input_voltage}
    end)
  end
end
