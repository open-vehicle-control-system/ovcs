defmodule VisionCore.FirmwareTest do
  use ExUnit.Case, async: false

  alias VisionCore.Firmware

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:vision_core, :firmware) end)
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

    assert %Firmware{nerves_system: "nerves_system_okdo_c100", nerves_system_version: "0.3.0"} =
             Firmware.current(path)
  end

  test "reads a quoted os-release value", %{tmp_dir: tmp_dir} do
    path =
      os_release(tmp_dir, """
      NERVES_SYSTEM_NAME="nerves_system_rpi5"
      NERVES_SYSTEM_VERSION='2.0.1'
      """)

    assert %Firmware{nerves_system: "nerves_system_rpi5", nerves_system_version: "2.0.1"} =
             Firmware.current(path)
  end

  test "has no Nerves system on a host", %{tmp_dir: tmp_dir} do
    path = os_release(tmp_dir, ~s(NAME="Ubuntu"\nVERSION_ID="24.04"\n))

    assert %Firmware{nerves_system: nil, nerves_system_version: nil} = Firmware.current(path)

    assert %Firmware{nerves_system: nil, nerves_system_version: nil} =
             Firmware.current(Path.join(tmp_dir, "missing"))
  end

  test "reports the commit and the target recorded at build time", %{tmp_dir: tmp_dir} do
    Application.put_env(:vision_core, :firmware, revision: "ce99e251-dirty", target: "rpi5")

    assert %Firmware{revision: "ce99e251-dirty", target: "rpi5"} =
             Firmware.current(Path.join(tmp_dir, "missing"))
  end

  test "has no commit or target when the firmware recorded none", %{tmp_dir: tmp_dir} do
    assert %Firmware{revision: nil, target: nil} = Firmware.current(Path.join(tmp_dir, "missing"))
  end
end
