defmodule VmsCore.Controllers.VmsController do
  use GenServer

  alias Cantastic.Emitter

  @network_name :drive

  @frame_name "vms_relays_status_request"

  @inverter_relay "inverter_relay_enabled"


  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @frame_name, %{
      parameters_builder_function: &vms_relays_status_request_frame_parameters/1,
      initial_data: %{
        @inverter_relay => false,
      }
    })
    Emitter.batch_enable(@network_name, [@frame_name])
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def vms_relays_status_request_frame_parameters(state) do
    {:ok, state.data, state}
  end

  def switch_on_inverter_relay() do
    actuate_relay(@inverter_relay, true)
  end

  def switch_off_inverter_relay() do
    actuate_relay(@inverter_relay, false)
  end

  defp actuate_relay(relay_name, enable) do
    Emitter.update(@network_name, @frame_name, fn (state) ->
      state |> put_in([:data, relay_name], enable)
    end)
  end
end
