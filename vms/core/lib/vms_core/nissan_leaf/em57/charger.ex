defmodule VmsCore.NissanLeaf.Em57.Charger do
  use GenServer
  alias VmsCore.NissanLeaf.Util
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @network_name :leaf_drive
  @charger_status_frame_name "charger_status"
  @charger_command_frame_name "charger_command"
  @zero D.new(0)

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = init_emitters()
    :ok = Receiver.subscribe(self(), @network_name, [@charger_status_frame_name])
    :ok = Emitter.enable(@network_name, @charger_command_frame_name)
    {:ok, %{
      ac_voltage: 0,
      charge_power: @zero
    }}
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, @charger_command_frame_name, %{
      parameters_builder_function: &charger_command_frame_parameters_builder/1,
      initial_data: %{
        "maximum_power_for_charger" => @zero,
        "counter" => 0
      }
    })
    :ok
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{
      "charge_power" => %Signal{value: charge_power},
      "ac_voltage"   => %Signal{value: ac_voltage}
    } = signals
    {:noreply, %{
      state |
        charge_power: charge_power,
        ac_voltage: ac_voltage
      }
    }
  end

  defp charger_command_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "maximum_power_for_charger" => data["maximum_power_for_charger"],
      "counter" => Util.counter(counter),
      "crc" => &Util.crc8/1
    }
    data = %{data | "counter" => Util.counter(counter + 1)}
    {:ok, parameters, data}
  end

  @impl true
  def handle_call(:ac_voltage, _from, state) do
    {:reply, {:ok, state.ac_voltage}, state}
  end

  def ac_voltage() do
    GenServer.call(__MODULE__, :ac_voltage)
  end

  def maximum_power_for_charger(maximum_power_for_charger) do
    :ok = Emitter.update(@network_name, @charger_command_frame_name, fn (data) ->
      %{data | "maximum_power_for_charger" => maximum_power_for_charger}
    end)
  end
end
