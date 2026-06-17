defmodule RosBridge.Publishers.Heartbeat.State do
  @moduledoc false
  defstruct [:topic, :message_module, :interval_ms, :build, counter: 0]
end

defmodule RosBridge.Publishers.Heartbeat do
  @moduledoc """
  Periodic ROS 2 publisher that ticks a caller-supplied message
  builder into `RosBridge.ZenohClient.publish/4`. Used by the bridge
  to advertise its presence (`std_msgs/String` on `ovcs_heartbeat`)
  so consumers can see that the BEAM is alive even when no other
  topic is flowing.

  Configured at start time:

      {RosBridge.Publishers.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2.StdMsgs.Msg.String,
       interval_ms: 5_000,
       build: fn counter ->
         %Ros2.StdMsgs.Msg.String{data: "heartbeat #\{counter}"}
       end}
  """
  use GenServer

  alias RosBridge.Publishers.Heartbeat.State

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      message_module: Keyword.fetch!(opts, :message_module),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      build: Keyword.fetch!(opts, :build)
    }

    Logger.info(
      "#{__MODULE__} ticking #{inspect(state.message_module)} on " <>
        "#{state.topic} every #{state.interval_ms}ms"
    )

    Process.send_after(self(), :tick, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    counter = state.counter + 1
    message = state.build.(counter)

    RosBridge.ZenohClient.publish(state.topic, state.message_module, message)

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, %{state | counter: counter}}
  end
end
