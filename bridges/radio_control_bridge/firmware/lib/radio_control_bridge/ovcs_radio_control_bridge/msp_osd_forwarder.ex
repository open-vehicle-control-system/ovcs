defmodule RadioControlBridgeFirmware.MspOsdForwarder.State do
  defstruct []
end

defmodule RadioControlBridgeFirmware.MspOsdForwarder do
  alias RadioControlBridgeFirmware.MspOsdForwarder.State

  require Logger
  use GenServer

  def init(_) do

    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug "Starting #{__MODULE__}..."
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end
end
