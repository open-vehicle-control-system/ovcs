defmodule RosBridge.ImuPublisher.State do
  @moduledoc false
  defstruct [
    :driver,
    :topic,
    :frame_id,
    :publish_interval_ms,
    latest_orientation: nil,
    latest_angular_velocity: nil,
    latest_linear_acceleration: nil
  ]
end

defmodule RosBridge.ImuPublisher do
  @moduledoc """
  Coalesces samples from an `OvcsDrivers.Imu` driver into
  `sensor_msgs/Imu` messages and publishes them via
  `RosBridge.ZenohClient.publish/4`.

  Knows nothing about any specific chip — any module implementing
  the `OvcsDrivers.Imu` behaviour plugs in via the `:driver` option.

  Samples arrive independently per kind; we keep the freshest of
  each and publish a single coalesced `Imu` at 50 Hz. The tick is a
  no-op until all three kinds we publish have been seen at least
  once (avoids emitting half-filled messages).

  TODO: characterize the source's noise floor and populate
  `*_covariance` arrays with measured values instead of the zero
  sentinel ("covariance unknown" per the ROS message definition).
  """
  use GenServer

  alias OvcsDrivers.Imu.Sample
  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.GeometryMsgs.Msg.Quaternion
  alias Ros2.GeometryMsgs.Msg.Vector3
  alias Ros2.SensorMsgs.Msg.Imu
  alias Ros2.StdMsgs.Msg.Header
  alias RosBridge.ImuPublisher.State

  require Logger

  @default_topic "imu"
  @default_frame_id "imu_link"
  # 50 Hz — fast enough for Foxglove's IMU visualizer to feel live,
  # slow enough not to drown a downstream consumer in samples.
  @default_publish_interval_ms 20

  # Nine-element zero list, the ROS sentinel for "covariance unknown"
  # (per the comment in the upstream sensor_msgs/Imu.msg IDL).
  @unknown_covariance List.duplicate(0.0, 9)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %State{
      driver: driver,
      topic: Keyword.get(opts, :topic, @default_topic),
      frame_id: Keyword.get(opts, :frame_id, @default_frame_id),
      publish_interval_ms:
        Keyword.get(opts, :publish_interval_ms, @default_publish_interval_ms)
    }

    driver.register_listener(self())
    driver.enable()
    Process.send_after(self(), :tick, state.publish_interval_ms)

    Logger.info(
      "#{__MODULE__} publishing Ros2.SensorMsgs.Msg.Imu on " <>
        "#{state.topic} every #{state.publish_interval_ms}ms " <>
        "(frame #{state.frame_id}, driver #{inspect(driver)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:imu_sample, %Sample{kind: :acceleration, x: x, y: y, z: z}}, state) do
    {:noreply, %{state | latest_linear_acceleration: %Vector3{x: x, y: y, z: z}}}
  end

  def handle_cast({:imu_sample, %Sample{kind: :angular_velocity, x: x, y: y, z: z}}, state) do
    {:noreply, %{state | latest_angular_velocity: %Vector3{x: x, y: y, z: z}}}
  end

  def handle_cast({:imu_sample, %Sample{kind: :rotation, x: x, y: y, z: z, w: w}}, state) do
    {:noreply, %{state | latest_orientation: %Quaternion{x: x, y: y, z: z, w: w}}}
  end

  # `:magnetometer` and `:temperature` aren't part of sensor_msgs/Imu;
  # drop them silently. A future MagneticField / Temperature publisher
  # would register its own listener on the driver and translate them.
  def handle_cast({:imu_sample, %Sample{}}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, %State{} = state) do
    if ready_to_publish?(state) do
      publish_imu(state)
    end

    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:noreply, state}
  end

  defp ready_to_publish?(%State{
         latest_orientation: orientation,
         latest_angular_velocity: angular_velocity,
         latest_linear_acceleration: linear_acceleration
       }) do
    not is_nil(orientation) and not is_nil(angular_velocity) and not is_nil(linear_acceleration)
  end

  defp publish_imu(%State{} = state) do
    now_ns = System.system_time(:nanosecond)

    message = %Imu{
      header: %Header{
        stamp: %Time{
          sec: div(now_ns, 1_000_000_000),
          nanosec: rem(now_ns, 1_000_000_000)
        },
        frame_id: state.frame_id
      },
      orientation: state.latest_orientation,
      orientation_covariance: @unknown_covariance,
      angular_velocity: state.latest_angular_velocity,
      angular_velocity_covariance: @unknown_covariance,
      linear_acceleration: state.latest_linear_acceleration,
      linear_acceleration_covariance: @unknown_covariance
    }

    RosBridge.ZenohClient.publish(state.topic, Imu, message)
  end
end
