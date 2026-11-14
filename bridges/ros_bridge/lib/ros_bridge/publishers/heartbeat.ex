defmodule RosBridge.Publishers.Heartbeat.State do
  @moduledoc false
  defstruct [:topic, :message_module, :interval_ms, :build, :node_name, counter: 0]
end

defmodule RosBridge.Publishers.Heartbeat do
  @moduledoc """
  Periodic ROS 2 publisher that ticks a caller-supplied message
  builder into `Ros2Zenoh.Client.publish/4`. Used by the bridge
  to advertise its presence (`std_msgs/String` on
  `<node_name>/heartbeat`, `topic/1`) so consumers can see that the
  BEAM is alive even when no other topic is flowing. The node name is
  read from `Ros2Zenoh.Client` once at start, and the builder gets it
  with the tick's counter.

  Configured at start time:

      {RosBridge.Publishers.Heartbeat,
       message_module: Ros2Zenoh.StdMsgs.Msg.String,
       interval_ms: 5_000,
       build: fn counter, node_name ->
         %Ros2Zenoh.StdMsgs.Msg.String{data: "#\{node_name} heartbeat #\{counter}"}
       end}
  """
  use GenServer

  alias RosBridge.Publishers.Heartbeat.State

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The heartbeat topic of the node `node_name`."
  @spec topic(String.t()) :: String.t()
  def topic(node_name), do: "#{node_name}/heartbeat"

  @impl GenServer
  def init(opts) do
    node_name = Ros2Zenoh.Client.node_name()

    state = %State{
      topic: topic(node_name),
      message_module: Keyword.fetch!(opts, :message_module),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      build: Keyword.fetch!(opts, :build),
      node_name: node_name
    }

    Logger.info(
      "#{__MODULE__} ticking #{inspect(state.message_module)} on " <>
        "#{state.topic} every #{state.interval_ms}ms"
    )

    Process.send_after(self(), :tick, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    counter = state.counter + 1
    message = state.build.(counter, state.node_name)

    Ros2Zenoh.Client.publish(state.topic, state.message_module, message)

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, %{state | counter: counter}}
  end
end
