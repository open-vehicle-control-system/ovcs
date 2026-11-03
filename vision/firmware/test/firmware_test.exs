defmodule VisionFirmwareTest do
  use ExUnit.Case, async: true

  test "declares the dashboard dev add-on" do
    assert [%{name: "dashboard", dir: "../dashboard"}] = VisionFirmware.dev_addons()
  end

  test "records the commit it is built from and its target, for VisionCore.Firmware" do
    firmware = Application.fetch_env!(:vision_core, :firmware)

    assert firmware[:target] == "host"
    assert firmware[:revision] =~ ~r/^(v\d\S*|[0-9a-f]{7,}(-dirty)?)$/
  end
end
