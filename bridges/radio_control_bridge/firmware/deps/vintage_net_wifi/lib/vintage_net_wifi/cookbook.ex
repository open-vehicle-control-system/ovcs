defmodule VintageNetWiFi.Cookbook do
  @moduledoc """
  Recipes for common WiFi network configurations

  For example, if you want the standard configuration for the most common type of WiFi
  network (WPA2 Preshared Key networks), pass the SSID and password to `wpa_psk/2`
  """

  alias VintageNetWiFi.WPA2

  @doc """
  Return a generic configuration for connecting to preshared-key networks

  The returned configuration should be able to connect to an access point
  configured to use WPA3-only, WPA2/3 transitional or WPA2. The WiFi module
  must also support WPA3 for this to work.

  Pass an SSID and passphrase. If the SSID and passphrase are ok, you'll get an
  `:ok` tuple with the configuration. If there's a problem, you'll get an error
  tuple with a reason.
  """
  @spec generic(String.t(), String.t()) ::
          {:ok, map()} | {:error, WPA2.invalid_ssid_error() | WPA2.invalid_passphrase_error()}
  def generic(ssid, passphrase) when is_binary(ssid) and is_binary(passphrase) do
    with :ok <- WPA2.validate_ssid(ssid),
         :ok <- WPA2.validate_passphrase(passphrase) do
      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               ssid: ssid,
               psk: passphrase,
               sae_password: passphrase,
               key_mgmt: [:wpa_psk, :wpa_psk_sha256, :sae],
               ieee80211w: 1
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    end
  end

  @doc """
  Return a configuration for connecting to open WiFi network

  Pass an SSID and passphrase. If the SSID and passphrase are ok, you'll get an
  `:ok` tuple with the configuration. If there's a problem, you'll get an error
  tuple with a reason.
  """
  @spec open_wifi(String.t()) :: {:ok, map()} | {:error, WPA2.invalid_ssid_error()}
  def open_wifi(ssid) when is_binary(ssid) do
    with :ok <- WPA2.validate_ssid(ssid) do
      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               key_mgmt: :none,
               ssid: ssid
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    end
  end

  @doc """
  Return a configuration for connecting to a WPA-PSK network

  Pass an SSID and passphrase. If the SSID and passphrase are ok, you'll get an
  `:ok` tuple with the configuration. If there's a problem, you'll get an error
  tuple with a reason.
  """
  @spec wpa_psk(String.t(), String.t()) ::
          {:ok, map()} | {:error, WPA2.invalid_ssid_error() | WPA2.invalid_passphrase_error()}
  def wpa_psk(ssid, passphrase) when is_binary(ssid) and is_binary(passphrase) do
    with :ok <- WPA2.validate_ssid(ssid),
         :ok <- WPA2.validate_passphrase(passphrase) do
      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               key_mgmt: :wpa_psk,
               ssid: ssid,
               psk: passphrase
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    end
  end

  @doc """
  Return a configuration for connecting to a WPA3 network

  Pass an SSID and passphrase. If the SSID and passphrase are ok, you'll get an
  `:ok` tuple with the configuration. If there's a problem, you'll get an error
  tuple with a reason.
  """
  @spec wpa3_sae(String.t(), String.t()) ::
          {:ok, map()} | {:error, WPA2.invalid_ssid_error() | WPA2.invalid_passphrase_error()}
  def wpa3_sae(ssid, passphrase) when is_binary(ssid) and is_binary(passphrase) do
    with :ok <- WPA2.validate_ssid(ssid),
         :ok <- WPA2.validate_passphrase(passphrase) do
      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               key_mgmt: :sae,
               ieee80211w: 2,
               sae_password: passphrase,
               ssid: ssid
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    end
  end

  @doc """
  Return a configuration for connecting to a WPA-EAP PEAP network

  Pass an SSID and login credentials. If valid, you'll get an
  `:ok` tuple with the configuration. If there's a problem, you'll get an error
  tuple with a reason.
  """
  @spec wpa_eap_peap(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, WPA2.invalid_ssid_error()}
  def wpa_eap_peap(ssid, username, passphrase)
      when is_binary(ssid) and is_binary(username) and is_binary(passphrase) do
    with :ok <- WPA2.validate_ssid(ssid) do
      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               key_mgmt: :wpa_eap,
               ssid: ssid,
               identity: username,
               password: passphrase,
               eap: "PEAP",
               phase2: "auth=MSCHAPV2"
             }
           ]
         },
         ipv4: %{method: :dhcp}
       }}
    end
  end

  @doc """
  Return a configuration for creating an open access point

  Pass an SSID and an optional IPv4 class C network.
  """
  @spec open_access_point(String.t(), VintageNet.any_ip_address()) ::
          {:ok, map()} | {:error, term()}
  def open_access_point(ssid, ipv4_subnet \\ "192.168.24.0") do
    with :ok <- WPA2.validate_ssid(ssid),
         {:ok, {a, b, c, _d}} <- VintageNet.IP.ip_to_tuple(ipv4_subnet) do
      our_address = {a, b, c, 1}
      dhcp_start = {a, b, c, 10}
      dhcp_end = {a, b, c, 250}

      {:ok,
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [
             %{
               mode: :ap,
               ssid: ssid,
               key_mgmt: :none
             }
           ]
         },
         ipv4: %{
           method: :static,
           address: our_address,
           netmask: {255, 255, 255, 0}
         },
         dhcpd: %{
           start: dhcp_start,
           end: dhcp_end
         }
       }}
    end
  end
end
