defmodule VmsCore.Components.Nissan.LeafZE0.Charger do
  @moduledoc """
    Nissan Leaf ZE0/EM57 Charger
    !! WIP implementation, does not work yet (charge is not starting) !!
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
        "maximum_power_for_charger" => D.new("27.3"),
        "counter" => 0,
        "charge_power_limit" => D.new("40"),
        "discharge_power_limit" => D.new("110")
      },
      enable: true
    })
    :ok = Emitter.configure(:leaf_drive, "nissan_bms_status_1", %{
      parameters_builder_function: &nissan_bms_status_1_frame_parameters_builder/1,
      initial_data: %{
        "current" => @zero,
        "total_voltage" => @zero,
        "counter" => 0
      },
      enable: true
    })
    :ok = Emitter.configure(:leaf_drive, "nissan_bms_status_2", %{
      parameters_builder_function: &nissan_bms_status_2_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      },
      enable: true
    })
    :ok = Emitter.configure(:leaf_drive, "lithium_battery_controller_status", %{
      parameters_builder_function: &lithium_battery_controller_status_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      },
      enable: true
    })
    :ok = Emitter.configure(:leaf_drive, "lithium_battery_controller_status2", %{
      parameters_builder_function: :default,
      initial_data: %{},
      enable: true
    })
    :ok = Emitter.configure(:leaf_drive, "lithium_battery_controller_status3", %{
      parameters_builder_function: :default,
      initial_data: %{},
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
      maximum_charge_power: nil,
      pack_current: @zero,
      emitted_pack_current: @zero,
      pack_instant_voltage: @zero,
      emitted_pack_instant_voltage: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      #|> handle_maximum_charge_power()
      |> handle_pack_current()
      |> handle_pack_instant_voltage()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :maximum_power_for_charger, value: maximum_power_for_charger, source: source}, state) when source == state.maximum_power_for_charger_source do
    {:noreply, %{state | maximum_power_for_charger: maximum_power_for_charger}}
  end
  def handle_info(%Bus.Message{name: :pack_current, value: pack_current, source: source}, state) when source == state.maximum_power_for_charger_source do
    {:noreply, %{state | pack_current: pack_current}}
  end
  def handle_info(%Bus.Message{name: :pack_instant_voltage, value: pack_instant_voltage, source: source}, state) when source == state.maximum_power_for_charger_source do
    {:noreply, %{state | pack_instant_voltage: pack_instant_voltage}}
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

  defp handle_pack_current(state) do
    case state.pack_current != state.emitted_pack_current do
      true ->
        :ok = Emitter.update(:leaf_drive, "nissan_bms_status_1", fn (data) ->
          %{data | "current" => state.pack_current}
        end)
        %{state | emitted_pack_current: state.pack_current}
      _ ->
        state
    end
  end

  defp handle_pack_instant_voltage(state) do
    case state.pack_instant_voltage != state.emitted_pack_instant_voltage do
      true ->
        :ok = Emitter.update(:leaf_drive, "nissan_bms_status_1", fn (data) ->
          %{data | "total_voltage" => state.pack_instant_voltage}
        end)
        %{state | emitted_pack_instant_voltage: state.pack_instant_voltage}
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

  def nissan_bms_status_1_frame_parameters_builder(data) do
    counter = data["counter"]
      parameters = %{
        "current" => data["current"],
        "total_voltage" => data["total_voltage"],
        "counter" => Util.counter(counter),
        "crc" => &Util.crc8/1
      }
      data = %{data | "counter" => Util.counter(counter + 1)}
      {:ok, parameters, data}
   end

   def nissan_bms_status_2_frame_parameters_builder(data) do
    counter = data["counter"]
      parameters = %{
        "counter" => Util.counter(counter),
        "crc" => &Util.crc8/1
      }
      data = %{data | "counter" => Util.counter(counter + 1)}
      {:ok, parameters, data}
   end

   def charger_command_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "charge_power_limit" => data["charge_power_limit"],
      "discharge_power_limit" => data["discharge_power_limit"],
      "maximum_power_for_charger" => data["maximum_power_for_charger"],
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }
    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end

  def lithium_battery_controller_status_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }
    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end

end
