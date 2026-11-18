defmodule OvcsVehicle.WifiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OvcsVehicle.Wifi

  @unconfigured %{type: VintageNet.Technology.Null}

  defp recorder(test_pid),
    do: fn ifname, config, options -> send(test_pid, {ifname, config, options}) end

  describe "vintage_net_config/2" do
    test "joins the site networks by DHCP" do
      assert {:ok,
              %{
                type: VintageNetWiFi,
                ipv4: %{method: :dhcp},
                vintage_net_wifi: %{networks: [network]}
              }} =
               Wifi.vintage_net_config(:join, networks: [{"Area42-Guest", "secret"}])

      assert network == %{key_mgmt: :wpa_psk, ssid: "Area42-Guest", psk: "secret"}
    end

    test "leaves wlan0 unconfigured to join no network, or when off" do
      assert Wifi.vintage_net_config(:join, networks: []) == {:ok, @unconfigured}
      assert Wifi.vintage_net_config(:join, []) == {:ok, @unconfigured}

      assert Wifi.vintage_net_config(:off, networks: [{"Area42-Guest", "secret"}]) ==
               {:ok, @unconfigured}
    end

    test "hosts a WPA2 hotspot at 192.168.4.1 on channel 6, handing out .10 to .50" do
      {:ok, config} =
        Wifi.vintage_net_config({:hotspot, ssid: "ovcs1-vision"}, hotspot_psk: "12345678")

      assert config.type == VintageNetWiFi

      assert config.vintage_net_wifi.networks ==
               [
                 %{
                   mode: :ap,
                   ssid: "ovcs1-vision",
                   key_mgmt: :wpa_psk,
                   psk: "12345678",
                   frequency: 2437
                 }
               ]

      assert config.ipv4 == %{method: :static, address: {192, 168, 4, 1}, prefix_length: 24}
      assert %{start: {192, 168, 4, 10}, end: {192, 168, 4, 50}} = config.dhcpd
    end

    test "refuses a hotspot without a passphrase of at least 8 characters" do
      assert {:error, _} =
               Wifi.vintage_net_config({:hotspot, ssid: "ovcs1-vision"}, hotspot_psk: nil)

      assert {:error, _} = Wifi.vintage_net_config({:hotspot, ssid: "ovcs1-vision"}, [])

      assert {:error, _} =
               Wifi.vintage_net_config({:hotspot, ssid: "ovcs1-vision"}, hotspot_psk: "1234567")
    end
  end

  describe "a mode VintageNet would refuse" do
    test "refuses a passphrase WPA2 rejects: over 63 characters, or not printable ASCII" do
      assert {:error, _} =
               Wifi.vintage_net_config({:hotspot, ssid: "x"},
                 hotspot_psk: String.duplicate("a", 64)
               )

      assert {:error, _} =
               Wifi.vintage_net_config({:hotspot, ssid: "x"}, hotspot_psk: "passé-partout")

      assert {:ok, _} =
               Wifi.vintage_net_config({:hotspot, ssid: "x"},
                 hotspot_psk: String.duplicate("a", 63)
               )
    end

    test "refuses a mode or a network it does not know, without raising" do
      assert {:error, _} = Wifi.vintage_net_config(:hotspot, hotspot_psk: "12345678")
      assert {:error, _} = Wifi.vintage_net_config({:hotspot, []}, hotspot_psk: "12345678")
      assert {:error, _} = Wifi.vintage_net_config(:station, [])
      assert {:error, _} = Wifi.vintage_net_config(:join, networks: [{"site"}])
    end
  end

  describe "configure/2" do
    test "applies the configuration to wlan0 without saving it" do
      assert Wifi.configure(:off, configure: recorder(self())) == :ok
      assert_received {"wlan0", @unconfigured, [persist: false]}
    end

    test "leaves wlan0 unconfigured and logs why when the mode is refused" do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   Wifi.configure({:hotspot, ssid: "ovcs1-vision"}, configure: recorder(self()))
        end)

      assert_received {"wlan0", @unconfigured, [persist: false]}
      assert log =~ "WIFI_HOTSPOT_PSK"
    end

    test "logs a configuration VintageNet refuses" do
      refuse = fn _ifname, _config, _options -> {:error, "SSID too long"} end

      log =
        capture_log(fn ->
          assert Wifi.configure(:off, configure: refuse) == {:error, "SSID too long"}
        end)

      assert log =~ "SSID too long"
    end
  end

  test "is not restarted once it has applied a mode" do
    assert Wifi.child_spec(mode: :off).restart == :temporary
  end

  test "applies a mode once when started" do
    {:ok, pid} = Wifi.start_link(mode: :off, configure: recorder(self()))
    ref = Process.monitor(pid)

    assert_receive {"wlan0", @unconfigured, [persist: false]}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
