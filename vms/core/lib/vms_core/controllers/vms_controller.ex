defmodule VmsCore.Controllers.VmsController do
  use GenServer

  alias Cantastic.{Frame, Signal, Emitter}

  @network_name :ovcs

  @status_request_frame_name "vms_relays_status_request"
  @status_frame_name "vms_relays_status"
  @inverter_relay "inverter_relay_enabled"


  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @status_frame_name)
    :ok = Emitter.configure(@network_name, @status_request_frame_name, %{
      parameters_builder_function: &vms_relays_status_request_frame_parameters/1,
      initial_data: %{
        @inverter_relay => false,
      }
    })
    Emitter.enable(@network_name, @status_request_frame_name)
    {:ok, %{
      inverter_relay_enabled: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp vms_relays_status_request_frame_parameters(data) do
    {:ok, data, data}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{"inverter_relay_enabled" => %Signal{value: inverter_relay_enabled}} = signals
    {:noreply, %{state | inverter_relay_enabled: inverter_relay_enabled}}
  end

  @impl true
  def handle_call(:ready_to_drive?,  _from, state) do
    {:reply, {:ok, state.inverter_relay_enabled}, state}
  end

  def ready_to_drive?() do
    GenServer.call(__MODULE__, :ready_to_drive?)
  end

  def switch_on_inverter_relay() do
    actuate_relay(@inverter_relay, true)
  end

  def switch_off_inverter_relay() do
    actuate_relay(@inverter_relay, false)
  end

  defp actuate_relay(relay_name, enable) do
    Emitter.update(@network_name, @status_request_frame_name, fn (data) ->
      %{data | relay_name => enable}
    end)
  end
end
