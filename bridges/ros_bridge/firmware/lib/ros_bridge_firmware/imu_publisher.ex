defmodule ROSBridgeFirmware.ImuPublisher.State do
  defstruct [:bno085_module]
end

defmodule ROSBridgeFirmware.ImuPublisher do
  @moduledoc false
  use GenServer
  alias ROSBridgeFirmware.ImuPublisher.State
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init([bno085_module: bno085_module]) do
    bno085_module.register_listener(self())
    # bno085_module.enable_all_sensors()
    {:ok, %State{bno085_module: bno085_module}}
  end

  @impl true
  def handle_cast({:bno085_sensor_message, %{name: sensor_name} = sensor_data}, state) do
    Logger.error("#{__MODULE__} IMU from #{sensor_name} #{inspect sensor_data}")
    {:noreply, state}
  end
end
