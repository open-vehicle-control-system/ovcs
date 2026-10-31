defmodule VisionFirmwareTest do
  use ExUnit.Case, async: true

  test "declares the dashboard dev add-on" do
    assert [%{name: "dashboard", dir: "../dashboard"}] = VisionFirmware.dev_addons()
  end
end
