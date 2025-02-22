defmodule VmsCore.Components.Nissan.LeafZE0.Charger do
  @moduledoc """
    Nissan Leaf ZE0/EM57 Charger
  """
  use GenServer

  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias VmsCore.Bus
  alias VmsCore.Components.Nissan.Util
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{maximum_power_for_charger_source: maximum_power_for_charger_source}) do
    :ok = Emitter.configure(:leaf_drive, "charger_command", %{
      parameters_builder_function: &charger_command_frame_parameters_builder/1,
      initial_data: %{
        "maximum_power_for_charger" => @zero,
        "counter" => 0,
        "charge_power_limit" => D.new("3.3"),
        "discharge_power_limit" => D.new("3.3")
      },
      enable: true
    })
    Bus.subscribe("messages")
    Receiver.subscribe(self(), :leaf_drive, ["charger_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      maximum_power_for_charger_source: maximum_power_for_charger_source,
      maximum_power_for_charger: 0,
      emitted_maximum_power_for_charger: 0,
      charge_power: nil,
      ac_voltage: 0,
      charging_state: nil,
      maximum_charge_power: nil
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_maximum_charge_power()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :maximum_power_for_charger, value: maximum_power_for_charger, source: source}, state) when source == state.maximum_power_for_charger_source do
    {:noreply, %{state | maximum_power_for_charger: maximum_power_for_charger}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "charger_status", signals: signals}}, state) do
    %{
      "charge_power" => %Signal{value: charge_power},
      "ac_voltage" => %Signal{value: ac_voltage},
      "charging_state" => %Signal{value: charging_state},
      "maximum_charge_power" => %Signal{value: maximum_charge_power}
    } = signals

    {:noreply, %{
      state |
        charge_power: charge_power,
        ac_voltage: ac_voltage,
        charging_state: charging_state,
        maximum_charge_power: maximum_charge_power
      }
    }
  end

  defp handle_maximum_charge_power(state) do
    case state.maximum_power_for_charger != state.emitted_maximum_power_for_charger do
      true ->
        :ok = Emitter.update(:leaf_drive, "charger_command", fn (data) ->
          %{data | "maximum_power_for_charger" => state.maximum_power_for_charger}
        end)
        %{state | emitted_maximum_power_for_charger: state.maximum_power_for_charger}
      _ ->
        state
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :charge_power, value: state.charge_power, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :ac_voltage, value: state.ac_voltage, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :charging_state, value: state.charging_state, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :maximum_charge_power, value: state.maximum_charge_power, source: __MODULE__})
    state
  end

  def charger_command_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "maximum_power_for_charger" => data["maximum_power_for_charger"],
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }
    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end
end
