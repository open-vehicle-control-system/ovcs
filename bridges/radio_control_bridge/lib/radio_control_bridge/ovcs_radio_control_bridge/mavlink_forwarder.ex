defmodule RadioControlBridge.MavlinkForwarder.State do
  defstruct []
end

defmodule RadioControlBridge.MavlinkForwarder do
  alias RadioControlBridge.MavlinkForwarder.State

  require Logger
  use GenServer

  def init(_) do
    :ok = ExpressLrs.Mavlink.Interpreter.register_listener(self())
    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug "Starting #{__MODULE__}..."
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_cast({:mavlink_message, mavlink_message}, state) do
    case mavlink_message.name do
      "RC_CHANNELS_OVERRIDE" ->
        mavlink_message.base_fields |> Enum.reduce("", fn field, acc -> acc <> " #{field.value}" end) |> Logger.debug
      _ -> mavlink_message
    end
    {:noreply, state}
  end

end
