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
end
