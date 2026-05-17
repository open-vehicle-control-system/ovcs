defmodule RosBridge.ImuPublisher.State do
  @moduledoc false
  defstruct [
    :bno085_module,
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
  Coalesces BNO085 sensor reports (accelerometer, calibrated
  gyroscope, rotation vector) into `sensor_msgs/Imu` samples and
  publishes them on `/imu` via `RosBridge.ZenohClient.publish/4`.

  BNO085 reports arrive independently per sensor at ~100 Hz; we keep
  the freshest reading for each axis source and publish a single
  coalesced `Imu` at 50 Hz. Until all three sensor streams have
  produced at least one sample the tick is a no-op (avoids emitting
  half-filled messages).

  TODO: characterize the BNO085 noise floor on a still bench and
  populate `*_covariance` arrays with measured values instead of
  the zero sentinel ("covariance unknown" per the ROS message
  definition).
  """
  use GenServer

  import Bitwise

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

  # The BNO chip soft-resets in its own `init/1`. Feature-enable
  # commands sent during the ~150 ms reboot window reach the I²C bus
  # but the chip silently drops them — observed on hardware as the
  # whole IMU publish path stalling on `latest_* = nil` forever. Wait
  # half a second before enabling. The driver doesn't yet surface a
  # "reset complete" notification we could synchronise on; if that
  # lands, switch to it.
  @sensor_enable_delay_ms 500

  # BNO085 SH-2 Q-point scaling — see the datasheet, section "Sensor
  # report data". Applied on intake so State always holds SI-unit
  # floats and the publish path doesn't have to know about Q-points.
  @accelerometer_scale 1.0 / (1 <<< 8)
  @gyroscope_scale 1.0 / (1 <<< 9)
  @quaternion_scale 1.0 / (1 <<< 14)

  # Nine-element zero list, the ROS sentinel for "covariance unknown"
  # (per the comment in the upstream sensor_msgs/Imu.msg IDL).
  @unknown_covariance List.duplicate(0.0, 9)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    bno085_module = Keyword.fetch!(opts, :bno085_module)

    state = %State{
      bno085_module: bno085_module,
      topic: Keyword.get(opts, :topic, @default_topic),
      frame_id: Keyword.get(opts, :frame_id, @default_frame_id),
      publish_interval_ms:
        Keyword.get(opts, :publish_interval_ms, @default_publish_interval_ms)
    }

    bno085_module.register_listener(self())
    Process.send_after(self(), :enable_sensors, @sensor_enable_delay_ms)
    Process.send_after(self(), :tick, state.publish_interval_ms)

    Logger.info(
      "#{__MODULE__} publishing Ros2.SensorMsgs.Msg.Imu on " <>
        "#{state.topic} every #{state.publish_interval_ms}ms (frame #{state.frame_id})"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:bno085_sensor_message, %{name: "accelerometer"} = report}, state) do
    {:noreply, %{state | latest_linear_acceleration: scale_vector3(report, @accelerometer_scale)}}
  end

  def handle_cast({:bno085_sensor_message, %{name: "calibrated_gyroscope"} = report}, state) do
    {:noreply, %{state | latest_angular_velocity: scale_vector3(report, @gyroscope_scale)}}
  end

  def handle_cast({:bno085_sensor_message, %{name: "rotation_vector"} = report}, state) do
    {:noreply, %{state | latest_orientation: scale_quaternion(report, @quaternion_scale)}}
  end

  # Uncalibrated gyroscope arrives alongside the calibrated one; we
  # prefer the calibrated stream so the bias-corrected values reach
  # consumers. Quietly drop the rest.
  def handle_cast({:bno085_sensor_message, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info(:enable_sensors, state) do
    state.bno085_module.enable_all_sensors()
    {:noreply, state}
  end

  def handle_info(:tick, %State{} = state) do
    state =
      if ready_to_publish?(state) do
        publish_imu(state)
        state
      else
        state
      end

    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:noreply, state}
  end

  defp ready_to_publish?(%State{
         latest_orientation: %Quaternion{},
         latest_angular_velocity: %Vector3{},
         latest_linear_acceleration: %Vector3{}
       }),
       do: true

  defp ready_to_publish?(_), do: false

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

  defp scale_vector3(%{x: x, y: y, z: z}, scale) do
    %Vector3{x: x * scale, y: y * scale, z: z * scale}
  end

  defp scale_quaternion(%{i: i, j: j, k: k, real: real}, scale) do
    %Quaternion{x: i * scale, y: j * scale, z: k * scale, w: real * scale}
  end
end
