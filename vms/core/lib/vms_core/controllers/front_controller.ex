defmodule VmsCore.Controllers.FrontController do
  use GenServer

  alias Cantastic.{Frame, Signal, Emitter}

  @network_name :ovcs

  @front_controller_request_frame_name "front_controller_request"
  @front_controller_status_frame_name "front_controller_status"
  @inverter_enabled "inverter_enabled"
  @water_pump_enabled "water_pump_enabled"


  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @front_controller_status_frame_name)
    :ok = Emitter.configure(@network_name, @front_controller_request_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @inverter_enabled   => false,
        @water_pump_enabled => false
      }
    })
    Emitter.enable(@network_name, @front_controller_request_frame_name)
    {:ok, %{
      inverter_enabled: false,
      water_pump_enabled: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{
      @inverter_enabled  => %Signal{value: inverter_enabled},
      @water_pump_enabled => %Signal{value: water_pump_enabled}
    } = signals
    {:noreply, %{state |
      inverter_enabled: inverter_enabled,
      water_pump_enabled: water_pump_enabled
    }}
  end

  @impl true
  def handle_call(:ready_to_drive?,  _from, state) do
    # TODO ensure that requested == status (with some delay)
    {:reply, {:ok, state.inverter_enabled}, state}
  end

  def ready_to_drive?() do
    GenServer.call(__MODULE__, :ready_to_drive?)
  end

  def switch_on_inverter() do
    actuate_relay(@inverter_enabled, true)
  end

  def switch_off_inverter() do
    actuate_relay(@inverter_enabled, false)
  end

  def switch_on_water_pump() do
    actuate_relay(@water_pump_enabled, true)
  end

  def switch_off_water_pump() do
    actuate_relay(@water_pump_enabled, false)
  end

  defp actuate_relay(relay_name, enable) do
    Emitter.update(@network_name, @front_controller_request_frame_name, fn (data) ->
      %{data | relay_name => enable}
    end)
  end
end
