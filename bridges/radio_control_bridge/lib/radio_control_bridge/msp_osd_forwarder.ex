defmodule RadioControlBridge.MspOsdForwarder.State do
  @moduledoc false
  defstruct []
end

defmodule RadioControlBridge.MspOsdForwarder do
  @moduledoc """
  Placeholder GenServer for the MSP OSD forward path: started for the
  `:msp_osd_forwarder` component, it holds no state and sends
  nothing.
  """
  alias RadioControlBridge.MspOsdForwarder.State

  require Logger
  use GenServer

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}…")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(_), do: {:ok, %State{}}
end
