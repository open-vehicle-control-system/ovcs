defmodule OvcsVehicle.FirmwareVehiclePathTest do
  # Sets OVCS_VEHICLE_PATH, which every resolve in the VM reads.
  use ExUnit.Case, async: false

  alias OvcsVehicle.Firmware

  @vehicle_dir "vehicle_path_test_vehicle"

  setup do
    root = Path.join(System.tmp_dir!(), "ovcs_vehicle_path_#{System.unique_integer([:positive])}")
    vehicle = Path.join(root, "elsewhere/ovcs-vehicle-path-test")
    ebin = Path.join(vehicle, "_build/dev/lib/#{@vehicle_dir}/ebin")
    File.mkdir_p!(ebin)

    [{module, beam}] =
      Code.compile_string("defmodule VehiclePathTestVehicle do\n  def vms, do: nil\nend\n")

    File.write!(Path.join(ebin, "#{module}.beam"), beam)

    File.write!(
      Path.join(ebin, "#{@vehicle_dir}.app"),
      ~s|{application, #{@vehicle_dir}, [{vsn, "0.0.0"}, {modules, ['#{module}']}]}.|
    )

    previous = System.get_env("OVCS_VEHICLE_PATH")
    System.put_env("OVCS_VEHICLE_PATH", vehicle)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVCS_VEHICLE_PATH", previous),
        else: System.delete_env("OVCS_VEHICLE_PATH")

      Code.delete_path(ebin)
      :application.unload(String.to_atom(@vehicle_dir))
      File.rm_rf!(root)
    end)

    {:ok, config_dir: Path.join(root, "ovcs/vms/firmware/config")}
  end

  test "resolve_vehicle/3 loads a vehicle compiled at OVCS_VEHICLE_PATH", %{
    config_dir: config_dir
  } do
    assert Firmware.resolve_vehicle(config_dir, :dev, "VehiclePathTestVehicle") ==
             VehiclePathTestVehicle
  end
end
