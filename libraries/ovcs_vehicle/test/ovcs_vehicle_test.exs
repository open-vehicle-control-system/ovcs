defmodule OvcsVehicleTest do
  use ExUnit.Case, async: true

  # The worked examples in `min_turning_radius/1` and `max_yaw_rate/2`
  # are the numbers OVCS Mini actually runs with, so running them keeps
  # the docs from drifting into fiction.
  doctest OvcsVehicle

  test "min_turning_radius refuses a vehicle that cannot steer" do
    # Zero steering limit means no achievable arc at all. Better to
    # fail the guard than divide by tan(0) and hand back infinity that
    # something downstream treats as a very wide turn.
    assert_raise FunctionClauseError, fn ->
      OvcsVehicle.min_turning_radius(%{wheelbase: 0.324, steering_limit: 0.0})
    end
  end

  test "max_yaw_rate is symmetric in the sign of speed" do
    geometry = %{wheelbase: 0.324, steering_limit: 0.52}
    assert OvcsVehicle.max_yaw_rate(geometry, -2.0) == OvcsVehicle.max_yaw_rate(geometry, 2.0)
  end

  test "a longer wheelbase cannot turn as tightly" do
    tight = OvcsVehicle.min_turning_radius(%{wheelbase: 0.324, steering_limit: 0.52})
    polo = OvcsVehicle.min_turning_radius(%{wheelbase: 2.466, steering_limit: 0.52})
    assert polo > tight
  end
end
