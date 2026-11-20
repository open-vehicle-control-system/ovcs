Code.require_file("../../config/vehicle_path.exs", __DIR__)

defmodule OvcsVehicle.VehiclePathTest do
  use ExUnit.Case, async: false

  alias OvcsVehicle.VehiclePath

  setup do
    previous = System.get_env("OVCS_VEHICLE_PATH")

    on_exit(fn ->
      if previous,
        do: System.put_env("OVCS_VEHICLE_PATH", previous),
        else: System.delete_env("OVCS_VEHICLE_PATH")
    end)
  end

  test "without OVCS_VEHICLE_PATH the vehicle is under vehicles/" do
    System.delete_env("OVCS_VEHICLE_PATH")
    assert VehiclePath.root("roomba", "/ovcs") == "/ovcs/vehicles/roomba"

    System.put_env("OVCS_VEHICLE_PATH", "")
    assert VehiclePath.root("roomba", "/ovcs") == "/ovcs/vehicles/roomba"
  end

  test "OVCS_VEHICLE_PATH wins, expanded" do
    System.put_env("OVCS_VEHICLE_PATH", "/src/ovcs-roomba/")
    assert VehiclePath.root("roomba", "/ovcs") == "/src/ovcs-roomba"

    System.put_env("OVCS_VEHICLE_PATH", "ovcs-roomba")
    assert VehiclePath.root("roomba", "/ovcs") == Path.join(File.cwd!(), "ovcs-roomba")
  end
end
