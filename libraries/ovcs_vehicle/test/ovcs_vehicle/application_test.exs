defmodule OvcsVehicle.ApplicationTest do
  use ExUnit.Case, async: true

  test "applies the firmware's Wi-Fi mode, with its networks and hotspot passphrase" do
    env = [
      wifi_mode: {:hotspot, ssid: "ovcs1-vision"},
      wifi_networks: [{"site", "pass"}],
      wifi_hotspot_psk: "12345678"
    ]

    assert OvcsVehicle.Application.children(env) == [
             {OvcsVehicle.Wifi,
              mode: {:hotspot, ssid: "ovcs1-vision"},
              networks: [{"site", "pass"}],
              hotspot_psk: "12345678"}
           ]
  end

  test "leaves the Wi-Fi to the firmware's VintageNet config without a mode" do
    assert OvcsVehicle.Application.children(wifi_networks: [{"site", "pass"}]) == []
  end
end
