defmodule RosBridge.Imu.Zenoh do
  @moduledoc """
  An IMU that is somewhere else: subscribes to a ROS
  `sensor_msgs/Imu` topic and hands the samples on as if it had read
  them over I2C.

  This is what lets the vehicle's own `/imu` exist against Gazebo. The
  simulated sensor publishes on `imu_raw`; this driver consumes it and
  casts the same `{:imu_sample, %Sample{}}` messages a `BNO085.I2C`
  does, so `Publishers.Imu` republishes on `/imu` and
  `Publishers.Odometry` reads its heading without either knowing the
  difference — the same pattern as `RosBridge.Camera.Zenoh` for the
  cameras, where swapping the driver is the entire difference between
  the car and the simulated car.

  Two topics on purpose: Gazebo owns `imu_raw`, the bridge owns
  `/imu`. One name for both would have the bridge republishing onto
  the topic it is consuming.

  One `sensor_msgs/Imu` fans out into the three sample kinds the
  hardware drivers produce — `:rotation`, `:angular_velocity`,
  `:acceleration` — because the contract is per-kind and consumers
  coalesce for themselves.

  ## Opts

    * `:topic` (`"imu_raw"`) — the ROS topic to consume.
  """
  @behaviour OvcsDrivers.Imu

  use GenServer

  require Logger

  alias OvcsDrivers.Imu.Sample
  alias Ros2.SensorMsgs.Msg.Imu

  @default_topic "imu_raw"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OvcsDrivers.Imu
  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end

  # Sample production is gated by the simulator publishing, not by
  # this process: there is no hardware to arm.
  @impl OvcsDrivers.Imu
  def enable, do: :ok

  @impl true
  def init(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)

    # Subscribing from `init/1` is safe: ZenohClient records the
    # subscription and declares it on the next successful connect.
    :ok = RosBridge.ZenohClient.subscribe(topic, Imu)

    Logger.info("#{__MODULE__} consuming #{topic}")

    {:ok, %{topic: topic, listeners: []}}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl true
  def handle_info({:ros_message, {_key_expr, %Imu{} = imu}}, state) do
    samples = samples(imu)

    Enum.each(state.listeners, fn l ->
      Enum.each(samples, &GenServer.cast(l, {:imu_sample, &1}))
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # `sensor_msgs/Imu` is already SI (REP-103: rad/s, m/s²,
  # unit quaternion), so this is a fan-out, not a conversion.
  @doc false
  def samples(%Imu{} = imu) do
    [
      %Sample{
        kind: :rotation,
        x: imu.orientation.x,
        y: imu.orientation.y,
        z: imu.orientation.z,
        w: imu.orientation.w
      },
      %Sample{
        kind: :angular_velocity,
        x: imu.angular_velocity.x,
        y: imu.angular_velocity.y,
        z: imu.angular_velocity.z
      },
      %Sample{
        kind: :acceleration,
        x: imu.linear_acceleration.x,
        y: imu.linear_acceleration.y,
        z: imu.linear_acceleration.z
      }
    ]
  end
end
