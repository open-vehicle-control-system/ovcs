defmodule OvcsVehicle.FirmwareInfoTest do
  use ExUnit.Case, async: false

  alias OvcsVehicle.FirmwareInfo

  @moduletag :tmp_dir

  defmodule Vehicle do
    @moduledoc false
    def name, do: "Test Car"
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:ovcs_vehicle, :firmware)
      Application.delete_env(:ovcs_vehicle, :module)
    end)
  end

  defp os_release(tmp_dir, contents) do
    path = Path.join(tmp_dir, "os-release")
    File.write!(path, contents)
    path
  end

  test "names the Nerves system of the board's os-release", %{tmp_dir: tmp_dir} do
    path =
      os_release(tmp_dir, """
      NAME=Nerves
      ID=nerves
      NERVES_SYSTEM_BR_VERSION=1.35.3
      NERVES_SYSTEM_NAME=nerves_system_okdo_c100
      NERVES_SYSTEM_VERSION=0.3.0
      NERVES_BUILDROOT_VERSION=2026.08.1
      """)

    assert %FirmwareInfo{nerves_system: "nerves_system_okdo_c100", nerves_system_version: "0.3.0"} =
             FirmwareInfo.current(path)
  end

  test "reads a quoted os-release value", %{tmp_dir: tmp_dir} do
    path =
      os_release(tmp_dir, """
      NERVES_SYSTEM_NAME="nerves_system_rpi5"
      NERVES_SYSTEM_VERSION='2.0.1'
      """)

    assert %FirmwareInfo{nerves_system: "nerves_system_rpi5", nerves_system_version: "2.0.1"} =
             FirmwareInfo.current(path)
  end

  test "has no Nerves system on a host", %{tmp_dir: tmp_dir} do
    path = os_release(tmp_dir, ~s(NAME="Ubuntu"\nVERSION_ID="24.04"\n))

    assert %FirmwareInfo{nerves_system: nil, nerves_system_version: nil} =
             FirmwareInfo.current(path)

    assert %FirmwareInfo{nerves_system: nil, nerves_system_version: nil} =
             FirmwareInfo.current(Path.join(tmp_dir, "missing"))
  end

  test "reports the commit and the target recorded at build time", %{tmp_dir: tmp_dir} do
    Application.put_env(:ovcs_vehicle, :firmware, revision: "ce99e251-dirty", target: "rpi5")

    assert %FirmwareInfo{revision: "ce99e251-dirty", target: "rpi5"} =
             FirmwareInfo.current(Path.join(tmp_dir, "missing"))
  end

  test "has no commit or target when the firmware recorded none", %{tmp_dir: tmp_dir} do
    assert %FirmwareInfo{revision: nil, target: nil} =
             FirmwareInfo.current(Path.join(tmp_dir, "missing"))
  end

  test "names the vehicle VEHICLE selects", %{tmp_dir: tmp_dir} do
    Application.put_env(:ovcs_vehicle, :module, Vehicle)

    assert %FirmwareInfo{vehicle: "Test Car"} =
             FirmwareInfo.current(Path.join(tmp_dir, "missing"))
  end

  test "has no vehicle without VEHICLE", %{tmp_dir: tmp_dir} do
    assert %FirmwareInfo{vehicle: nil} = FirmwareInfo.current(Path.join(tmp_dir, "missing"))
  end
end
