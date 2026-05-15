defmodule RadioControlBridge.MspOsdForwarder.State do
  defstruct []
end

defmodule RadioControlBridge.MspOsdForwarder do
  @moduledoc """
  Placeholder GenServer for the MSP OSD forward path. Not yet wired
  into `RadioControlBridge.children/0`; kept as a skeleton ported
  from the legacy firmware so the integration work can land
  incrementally.
  """
  alias RadioControlBridge.MspOsdForwarder.State

  require Logger
  use GenServer

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}…")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_), do: {:ok, %State{}}
end
