defmodule OvcsVehicle.FirmwareTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.Firmware

  @vehicle_dir "firmware_test_vehicle"

  setup do
    root =
      Path.join(System.tmp_dir!(), "ovcs_vehicle_firmware_#{System.unique_integer([:positive])}")

    ebin = Path.join(root, "vehicles/#{@vehicle_dir}/_build/dev/lib/#{@vehicle_dir}/ebin")
    File.mkdir_p!(ebin)

    [{module, beam}] =
      Code.compile_string("""
      defmodule FirmwareTestVehicle do
        def vms, do: FirmwareTestVehicle.Vms
        def vision, do: FirmwareTestVehicle.Vision
      end
      """)

    File.write!(Path.join(ebin, "#{module}.beam"), beam)

    File.write!(
      Path.join(ebin, "#{@vehicle_dir}.app"),
      ~s|{application, #{@vehicle_dir}, [{vsn, "0.0.0"}, {modules, ['#{module}']}]}.|
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, config_dir: Path.join(root, "a/b/c")}
  end

  test "resolve_side(:vision, ...) returns the vision composer", %{config_dir: config_dir} do
    assert {FirmwareTestVehicle, FirmwareTestVehicle.Vision} =
             Firmware.resolve_side(:vision, config_dir, :dev, "FirmwareTestVehicle")
  end

  test "resolve_side(:vision, ...) is nil in the test env", %{config_dir: config_dir} do
    assert Firmware.resolve_side(:vision, config_dir, :test, "FirmwareTestVehicle") == nil
  end
end
