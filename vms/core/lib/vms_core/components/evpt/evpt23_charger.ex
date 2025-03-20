defmodule VmsCore.Components.Evpt.Evpt23Charger do
  @moduledoc """
    EVPT23 Charger
  """
  use GenServer
  alias VmsCore.Bus

  require Logger
  alias Cantastic.{Frame, Receiver, Signal}
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :orion_bms, "charger_status")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      output_voltage: nil,
      output_current: nil,
      communication_timeout_failure: nil,
      battery_disconnected_or_reverse_connection_protection_enabled: nil,
      ac_voltage_over_protection_enabled: nil,
      charger_over_temperature_protection_enabled: nil,
      hardware_failure: nil,
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
  def handle_info({:handle_frame,  %Frame{name: "charger_status", signals: signals}}, state) do
    %{
      "output_voltage" => %Signal{value: output_voltage},
      "output_current" => %Signal{value: output_current},
      "communication_timeout_failure" => %Signal{value: communication_timeout_failure},
      "battery_disconnected_or_reverse_connection_protection_enabled" => %Signal{value: battery_disconnected_or_reverse_connection_protection_enabled},
      "ac_voltage_over_protection_enabled" => %Signal{value: ac_voltage_over_protection_enabled},
      "charger_over_temperature_protection_enabled" => %Signal{value: charger_over_temperature_protection_enabled},
      "hardware_failure" => %Signal{value: hardware_failure},
    } = signals
    {:noreply, %{state |
      output_voltage: output_voltage,
      output_current: output_current,
      communication_timeout_failure: communication_timeout_failure,
      battery_disconnected_or_reverse_connection_protection_enabled: battery_disconnected_or_reverse_connection_protection_enabled,
      ac_voltage_over_protection_enabled: ac_voltage_over_protection_enabled,
      charger_over_temperature_protection_enabled: charger_over_temperature_protection_enabled,
      hardware_failure: hardware_failure,
    }}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :output_voltage, value: state.output_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :output_current, value: state.output_current, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :communication_timeout_failure, value: state.communication_timeout_failure, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :battery_disconnected_or_reverse_connection_protection_enabled, value: state.battery_disconnected_or_reverse_connection_protection_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :ac_voltage_over_protection_enabled, value: state.ac_voltage_over_protection_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :charger_over_temperature_protection_enabled, value: state.charger_over_temperature_protection_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :hardware_failure, value: state.hardware_failure, source: __MODULE__})
    state
  end
end
