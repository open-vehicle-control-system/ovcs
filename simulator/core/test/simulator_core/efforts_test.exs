defmodule SimulatorCore.EffortsTest do
  use ExUnit.Case, async: true

  alias SimulatorCore.Efforts

  describe "combine/2" do
    test "drive torques add" do
      efforts = Efforts.combine([{:drive_torque_nm, 10.0}, {:drive_torque_nm, -4.0}], 0.0)

      assert efforts.drive_torque_nm == 6.0
    end

    test "brake torques add as magnitudes" do
      efforts = Efforts.combine([{:brake_torque_nm, 5.0}, {:brake_torque_nm, -3.0}], 0.0)

      assert efforts.brake_torque_nm == 8.0
    end

    test "the last steering wins" do
      efforts = Efforts.combine([{:steering_rad, 0.1}, {:steering_rad, 0.2}], 0.0)

      assert efforts.steering_rad == 0.2
    end

    test "no steering keeps the previous one" do
      assert Efforts.combine([], 0.3).steering_rad == 0.3
    end

    test "inertias add" do
      efforts =
        Efforts.combine(
          [{:driveline_inertia_kg_m2, 1.5}, {:driveline_inertia_kg_m2, 1.5}],
          0.0
        )

      assert efforts.driveline_inertia_kg_m2 == 3.0
    end

    test "no actuation is no effort" do
      assert Efforts.combine([], 0.0) == %Efforts{}
    end
  end
end
