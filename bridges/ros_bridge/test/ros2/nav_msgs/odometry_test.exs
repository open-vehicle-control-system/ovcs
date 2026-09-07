defmodule Ros2.NavMsgs.Msg.OdometryTest do
  @moduledoc """
  The wire layout, checked at the byte level: CDR offsets are the one
  thing a subscriber cannot forgive, and the only alignment hazard is
  the `child_frame_id` → `pose` boundary.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion}
  alias Ros2.GeometryMsgs.Msg.{Twist, TwistWithCovariance, Vector3}
  alias Ros2.NavMsgs.Msg.Odometry
  alias Ros2.StdMsgs.Msg.Header

  defp message do
    %Odometry{
      header: %Header{stamp: %Time{sec: 7, nanosec: 9}, frame_id: "odom"},
      child_frame_id: "base_link",
      pose: %PoseWithCovariance{
        pose: %Pose{
          position: %Point{x: 1.5, y: -2.25, z: 0.0},
          orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.5, w: 0.5}
        }
      },
      twist: %TwistWithCovariance{
        twist: %Twist{
          linear: %Vector3{x: 0.75, y: 0.0, z: 0.0},
          angular: %Vector3{x: 0.0, y: 0.0, z: -0.5}
        }
      }
    }
  end

  test "the body is the fixed size the IDL implies" do
    # Header 20 ("odom"), child_frame_id 16 ("base_link"), aligned to
    # 40; pose 56 + 288, twist 48 + 288.
    assert byte_size(Odometry.encode(message())) == 720
  end

  test "the pose lands 8-aligned after the strings" do
    body = Odometry.encode(message())
    <<_::binary-size(40), x::little-float-size(64), y::little-float-size(64), _::binary>> = body
    assert x == 1.5
    assert y == -2.25
  end

  test "the twist follows the pose covariance" do
    body = Odometry.encode(message())
    <<_::binary-size(384), vx::little-float-size(64), _::binary>> = body
    assert vx == 0.75

    <<_::binary-size(384 + 40), yaw_rate::little-float-size(64), _::binary>> = body
    assert yaw_rate == -0.5
  end
end
