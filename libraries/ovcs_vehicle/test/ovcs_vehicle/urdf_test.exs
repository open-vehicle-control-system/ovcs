defmodule OvcsVehicle.URDFTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.URDF

  @urdf URDF.read!(Path.expand("../fixtures/robot.urdf", __DIR__))

  test "reads a joint's origin and limit" do
    assert %{
             type: "revolute",
             parent: "chassis",
             xyz: {0.162, 0.148, 0.0522},
             rpy: {+0.0, +0.0, +0.0},
             limit: {-0.66, 0.66}
           } = URDF.joint!(@urdf, "steering_joint")

    assert URDF.joint!(@urdf, "chassis_joint").limit == nil
  end

  test "reads a link's collision cylinder" do
    assert URDF.collision_cylinder!(@urdf, "wheel") == %{radius: 0.0522, length: 0.045}
  end

  test "places each frame on the root through every fixed joint, once" do
    transforms = URDF.static_transforms(@urdf, ["camera_optical", "lidar_link", "camera_link"])

    assert Enum.map(transforms, &{&1.parent, &1.child}) == [
             {"base_link", "chassis"},
             {"chassis", "camera_link"},
             {"camera_link", "camera_optical"},
             {"base_link", "lidar_link"}
           ]
  end

  test "turns rpy into the quaternion of the same rotation" do
    rotations =
      Map.new(
        URDF.static_transforms(@urdf, ["camera_optical", "lidar_link"]),
        &{&1.child, &1.rotation}
      )

    for {child, expected} <- [
          {"chassis", {0.0, 0.0, 0.0, 1.0}},
          # The body to optical frame change.
          {"camera_optical", {-0.5, 0.5, -0.5, 0.5}},
          {"lidar_link", {0.0, 0.0, 1.0, 0.0}}
        ] do
      for {actual, wanted} <- Enum.zip(Tuple.to_list(rotations[child]), Tuple.to_list(expected)),
          do: assert_in_delta(actual, wanted, 1.0e-12)
    end
  end

  test "refuses a frame the URDF does not have" do
    assert_raise ArgumentError, ~r/camera_lnk is not a link in the URDF/, fn ->
      URDF.static_transforms(@urdf, ["camera_lnk"])
    end
  end

  test "refuses a frame a moving joint places" do
    assert_raise ArgumentError, ~r/wheel_joint places wheel but is continuous/, fn ->
      URDF.static_transforms(@urdf, ["wheel"])
    end
  end
end
