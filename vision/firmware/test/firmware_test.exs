defmodule VisionFirmwareTest do
  use ExUnit.Case, async: false

  test "declares the dashboard dev add-on" do
    assert [%{name: "dashboard", dir: "../dashboard"}] = VisionFirmware.dev_addons()
  end

  test "records the commit it is built from and its target, for OvcsVehicle.FirmwareInfo" do
    firmware = Application.fetch_env!(:ovcs_vehicle, :firmware)

    assert firmware[:target] == "host"
    assert firmware[:revision] =~ ~r/^(v\d\S*|[0-9a-f]{7,}(-dirty)?)$/
  end

  describe "erlinit" do
    test "starts the VENTUNO Q's VM with 512 MiB Vulkan slabs, and no other target's" do
      assert erlinit_env(:arduino_ventuno_q) == ["IREE_HAL_VULKAN_SLAB_SIZE=536870912"]
      assert erlinit_env(:okdo_c100) == []
      assert erlinit_env(:rpi5) == []
    end
  end

  describe "Wi-Fi" do
    defmodule Hotspot do
      def config(:target), do: %VisionCore.Config{wifi: {:hotspot, ssid: "ovcs1-vision"}}
    end

    defmodule Broken do
      def config(:target), do: raise("no camera")
    end

    test "hands the networks and the hotspot passphrase of .env.exs to OvcsVehicle.Wifi" do
      # A vehicle without a `.env.exs`, whose values would override these.
      config =
        target_config(:arduino_ventuno_q, %{
          "VEHICLE" => "WifiTestVehicle",
          "WIFI_NETWORKS" => ~s([{"site", "pass"}]),
          "WIFI_HOTSPOT_PSK" => "12345678"
        })

      refute List.keymember?(config[:vintage_net][:config], "wlan0", 0)
      assert config[:ovcs_vehicle][:wifi_networks] == [{"site", "pass"}]
      assert config[:ovcs_vehicle][:wifi_hotspot_psk] == "12345678"
    end

    test "reads the composer's mode, joining when the composer cannot say" do
      assert VisionFirmware.wifi_mode(Hotspot) == {:hotspot, ssid: "ovcs1-vision"}
      assert VisionFirmware.wifi_mode(Broken) == :join
    end

    test "refuses a hotspot build without a passphrase WPA2 takes" do
      assert VisionFirmware.check_wifi(Hotspot, "12345678") == :ok
      assert {:error, message} = VisionFirmware.check_wifi(Hotspot, nil)
      assert message =~ "WIFI_HOTSPOT_PSK"
      assert {:error, _} = VisionFirmware.check_wifi(Hotspot, "short")
      assert VisionFirmware.check_wifi(Broken, nil) == :ok
    end
  end

  test "a board restarts its applications when one exits" do
    assert target_config(:rpi5)[:shoehorn][:handler] == VisionFirmware.ShoehornHandler
  end

  describe "the API on a board" do
    test "serves HTTPS on port 443 with a certificate kept on the application partition" do
      https = target_config(:arduino_ventuno_q)[:vision_api][VisionApiWeb.Endpoint][:https]

      assert https[:port] == 443
      assert Path.dirname(https[:certfile]) == "/data/vision_api"
      assert Path.dirname(https[:keyfile]) == "/data/vision_api"
    end

    test "takes socket connections only from the pages it served itself" do
      endpoint = target_config(:arduino_ventuno_q)[:vision_api][VisionApiWeb.Endpoint]

      assert endpoint[:check_origin] == :conn
    end

    test "redirects plain HTTP from port 80 and from port 4100, where it served plain HTTP before" do
      vision_api = target_config(:arduino_ventuno_q)[:vision_api]

      assert vision_api[VisionApiWeb.Endpoint][:http] == nil
      assert vision_api[:https_redirect_ports] == [80, 4100]
    end
  end

  defp erlinit_env(target) do
    erlinit = get_in(target_config(target), [:nerves, :erlinit]) || []
    Keyword.get_values(erlinit, :env)
  end

  defp target_config(target, extra_env \\ %{}) do
    env =
      Map.merge(%{"VEHICLE" => "Ovcs1", "CI" => "true", "SECRET_KEY_BASE" => "test"}, extra_env)

    saved = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(env)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = Config.Reader.read!("config/target.exs", env: :test, target: target)
        send(self(), {:config, config})
      end)

      assert_received {:config, config}
      config
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
