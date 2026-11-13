defmodule SimulatorRunner.SimulatorTest do
  use ExUnit.Case, async: true

  alias SimulatorRunner.Simulator

  defmodule SimulatedVehicle do
    def simulator,
      do: %{
        vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522},
        simulated_components: [{SomeComponent, pin: 3}],
        can_config_path: "can/simulator.yml",
        can_mapping: "ovcs:vcan0,misc:vcan1"
      }
  end

  defmodule UnsimulatedVehicle do
    def name, do: "Unsimulated"
  end

  describe "fetch!/1" do
    test "reads the vehicle's simulator" do
      assert %{can_config_path: "can/simulator.yml"} = Simulator.fetch!(SimulatedVehicle)
    end

    test "names a vehicle that declares no simulator" do
      assert_raise ArgumentError, ~r/UnsimulatedVehicle.*simulator\/0/, fn ->
        Simulator.fetch!(UnsimulatedVehicle)
      end
    end
  end

  describe "can_network_mappings/1" do
    test "reads a host mapping as Cantastic takes it" do
      assert Simulator.can_network_mappings("ovcs:vcan0,misc:vcan1") ==
               [{"ovcs", "vcan0"}, {"misc", "vcan1"}]
    end

    test "names an entry that is not network:interface" do
      assert_raise ArgumentError, ~r/"vcan1"/, fn ->
        Simulator.can_network_mappings("ovcs:vcan0,vcan1")
      end
    end
  end

  test "hardware_options/1 runs the simulated components on the vehicle's motion model, with no world" do
    assert Simulator.hardware_options(SimulatedVehicle.simulator()) == [
             vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522},
             simulated_components: [{SomeComponent, pin: 3}]
           ]
  end
end
