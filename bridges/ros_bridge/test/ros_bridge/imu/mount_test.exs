defmodule RosBridge.Imu.MountTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias RosBridge.Imu.Mount

  test "an upside-down sensor reverses its gyro z axis" do
    mount = Mount.quaternion({:math.pi(), 0.0, 0.0})
    {x, y, z} = Mount.vector(%{x: 0.0, y: 0.0, z: -1.0}, mount)
    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, 1.0, 1.0e-9
  end

  test "a stationary mounted sensor resolves to identity vehicle orientation" do
    mount = Mount.quaternion({0.3, -0.2, 0.8})
    {x, y, z, w} = mount
    {x, y, z, w} = Mount.orientation(%{x: 2 * x, y: 2 * y, z: 2 * z, w: 2 * w}, mount)
    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, 0.0, 1.0e-9
    assert_in_delta w, 1.0, 1.0e-9
  end
end
