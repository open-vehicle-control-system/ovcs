defmodule RosBridge.Consumers.Joy.State do
  defstruct []
end

defmodule RosBridge.Consumers.Joy do
  @moduledoc """
  Subscribes to the ROS 2 `joy` topic via the native-Zenoh client
  (`RosBridge.ZenohClient.subscribe/2`) and translates each
  `sensor_msgs/Joy` sample into Cantastic emitter updates on
  `ros_control0`/`ros_control1`.
  """
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias Ros2.SensorMsgs.Msg.Joy
  alias RosBridge.Consumers.Joy.State

  require Logger
  use GenServer

  @max_value 2 ** 31 - 1
  @joy_topic "joy"

  @impl true
  def init(_) do
    :ok =
      Emitter.configure(:ovcs, "ros_control0", %{
        parameters_builder_function: :default,
        initial_data: %{
          "control_level" => "joy",
          "direction" => "forward"
        },
        enable: true
      })

    :ok =
      Emitter.configure(:ovcs, "ros_control1", %{
        parameters_builder_function: :default,
        initial_data: %{
          "throttle" => D.new(0),
          "steering" => D.new(0)
        },
        enable: true
      })

    :ok = RosBridge.ZenohClient.subscribe(@joy_topic, Joy)
    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info({:ros_message, {_key_expr, %Joy{axes: axes}}}, state) do
    steering = axes |> Enum.at(0) |> D.from_float() |> D.mult(-@max_value)
    throttle = axes |> Enum.at(1) |> D.from_float() |> D.mult(@max_value)

    :ok =
      Emitter.update(:ovcs, "ros_control1", fn data ->
        %{data | "steering" => steering, "throttle" => throttle}
      end)

    {:noreply, state}
  end

  # Anything else delivered as `{:ros_message, …}` is a configuration
  # bug (wrong subscribe call somewhere): log loudly rather than
  # silently dropping or matching on the wrong shape.
  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning(
      "#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}"
    )

    {:noreply, state}
  end
end
