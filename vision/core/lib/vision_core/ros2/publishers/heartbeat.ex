defmodule VisionCore.Ros2.Publishers.Heartbeat.State do
  @moduledoc false
  defstruct [:topic, :message_module, :interval_ms, :build, :node_name, counter: 0]
end

defmodule VisionCore.Ros2.Publishers.Heartbeat do
  @moduledoc """
  Periodic ROS 2 publisher that ticks a caller-supplied message
  builder into `VisionCore.Ros2.ZenohClient.publish/4`. Used by the vision core
  to advertise its presence (`std_msgs/String` on `ovcs_heartbeat`)
  so consumers can see that the BEAM is alive even when no other
  topic is flowing. The builder gets the tick's counter and the
  vision core's node name, read from `VisionCore.Ros2.ZenohClient` once at start,
  so nodes sharing the topic tell themselves apart.

  Configured at start time:

      {VisionCore.Ros2.Publishers.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2Zenoh.StdMsgs.Msg.String,
       interval_ms: 5_000,
       build: fn counter, node_name ->
         %Ros2Zenoh.StdMsgs.Msg.String{data: "#\{node_name} heartbeat #\{counter}"}
       end}
  """
  use GenServer

  alias VisionCore.Ros2.Publishers.Heartbeat.State

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      message_module: Keyword.fetch!(opts, :message_module),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      build: Keyword.fetch!(opts, :build),
      node_name: VisionCore.Ros2.ZenohClient.node_name()
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

    VisionCore.Ros2.ZenohClient.publish(state.topic, state.message_module, message)

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, %{state | counter: counter}}
  end
end
