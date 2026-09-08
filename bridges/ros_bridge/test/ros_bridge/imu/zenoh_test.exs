defmodule RosBridge.Imu.ZenohTest do
  @moduledoc """
  One `sensor_msgs/Imu` fans out into the three sample kinds the
  hardware drivers produce, values passed through untouched — the
  message is already SI, so anything but identity would be a bug.
  """
  use ExUnit.Case, async: true

  alias OvcsDrivers.Imu.Sample
  alias Ros2.GeometryMsgs.Msg.{Quaternion, Vector3}
  alias Ros2.SensorMsgs.Msg.Imu

  test "fans one message out into rotation, angular velocity and acceleration" do
    imu = %Imu{
      orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.3826834, w: 0.9238795},
      angular_velocity: %Vector3{x: 0.01, y: -0.02, z: 0.5},
      linear_acceleration: %Vector3{x: 0.1, y: 0.0, z: 9.81}
    }

    assert [
             %Sample{kind: :rotation, z: 0.3826834, w: 0.9238795},
             %Sample{kind: :angular_velocity, x: 0.01, y: -0.02, z: 0.5},
             %Sample{kind: :acceleration, x: 0.1, y: +0.0, z: 9.81}
           ] = RosBridge.Imu.Zenoh.samples(imu)
  end
end
