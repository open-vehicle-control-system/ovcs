defmodule Ovcs1.GeometryTest do
  @moduledoc """
  OVCS1's geometry is the Volkswagen Polo 9N's, from its published
  specifications, and the simulator moves the vehicle on it.
  """
  use ExUnit.Case, async: true

  test "the wheelbase is the Polo 9N's" do
    assert Ovcs1.geometry().wheelbase == 2.46
  end

  test "the wheel radius is a 185/60 R14 tyre's" do
    assert_in_delta Ovcs1.geometry().wheel_radius,
                    (14 * 25.4 + 2 * 185 * 0.60) / 2 / 1000,
                    1.0e-12
  end

  test "the track is the Polo 9N's rear track" do
    assert Ovcs1.geometry().track == 1.425
  end

  test "at full lock, the outer front wheel follows the Polo 9N's 10.6 m turning circle" do
    geometry = Ovcs1.geometry()
    front_track = 1.435
    outer_front_offset = OvcsVehicle.min_turning_radius(geometry) + front_track / 2

    assert_in_delta 2 * :math.sqrt(outer_front_offset ** 2 + geometry.wheelbase ** 2),
                    10.6,
                    1.0e-9
  end

  test "the simulator moves the vehicle on its geometry" do
    vehicle = Ovcs1.simulator().vehicle

    assert vehicle.wheelbase_m == Ovcs1.geometry().wheelbase
    assert vehicle.wheel_radius_m == Ovcs1.geometry().wheel_radius
  end
end
