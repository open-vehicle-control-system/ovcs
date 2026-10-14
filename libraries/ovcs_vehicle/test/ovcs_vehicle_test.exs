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

  describe "OvcsVehicle.Scaffold" do
    alias OvcsVehicle.Scaffold

    test "a display name is plain text" do
      assert Scaffold.valid_display_name?("OVCS Mini #2")
      refute Scaffold.valid_display_name?(~S|Shop "car"|)
      refute Scaffold.valid_display_name?(~S|Shop \ car|)
      refute Scaffold.valid_display_name?(~S|Shop #{System.halt(9)}|)
    end

    test "generate refuses a display name it cannot insert" do
      dir = Path.join(System.tmp_dir!(), "ovcs_scaffold_#{System.unique_integer([:positive])}")

      assert {:error, {:invalid_display_name, _}} =
               Scaffold.generate(dir,
                 module: "Car",
                 name: "car",
                 display_name: ~S|#{oops}|,
                 vms_target: "ovcs_base_can_system_rpi4",
                 infotainment_target: nil,
                 infotainment: false,
                 bridges: false
               )

      refute File.exists?(dir)
    end
  end
end
