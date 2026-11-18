defmodule OvcsVehicle.Wifi do
  @moduledoc """
  Sets `wlan0` to a vehicle's Wi-Fi mode once, at start, without saving it,
  so that every boot follows the mode its firmware runs with, whatever
  VintageNet saved before.

  Modes:

    * `:join` — joins the `:networks`, `{ssid, psk}` pairs, by DHCP;
      unconfigured when there are none.
    * `{:hotspot, ssid: ssid}` — hosts `ssid`, WPA2 with `:hotspot_psk`, at
      `192.168.4.1/24` on channel 6, handing out `192.168.4.10` to
      `192.168.4.50`. Without a passphrase of at least 8 characters, WPA2's
      shortest, `wlan0` stays unconfigured and the error is logged.
    * `:off` — unconfigured.

  Options: `:mode` (`:join`), `:networks`, `:hotspot_psk`, and
  `:configure`, for tests, a function of the interface, its configuration
  and VintageNet's options.

  Wired in only on target, like `OvcsVehicle.ClockSync`:

      {OvcsVehicle.Wifi, mode: {:hotspot, ssid: "ovcs1-vision"}, hotspot_psk: psk}
  """

  use Task, restart: :transient

  require Logger

  @ifname "wlan0"

  # Resolved at runtime, as in `OvcsVehicle.ClockSync`: this library does
  # not depend on VintageNet, and the firmwares bring it.
  @vintage_net_parts [:VintageNet]

  @unconfigured %{type: VintageNet.Technology.Null}
  @min_psk_length 8
  # Channel 6, on 2.4 GHz, which every phone supports.
  @hotspot_frequency 2437
  @hotspot_address {192, 168, 4, 1}

  @type mode :: :join | {:hotspot, [ssid: String.t()]} | :off

  @doc "Applies `opts[:mode]` once, as `configure/2` does."
  def start_link(opts),
    do: Task.start_link(fn -> configure(Keyword.get(opts, :mode, :join), opts) end)

  @doc """
  Applies `mode` to `wlan0` without saving it; a refused mode leaves
  `wlan0` unconfigured and logs why.
  """
  @spec configure(mode(), keyword()) :: :ok | {:error, String.t()}
  def configure(mode, opts \\ []) do
    configure = Keyword.get(opts, :configure, &vintage_net_configure/3)

    case vintage_net_config(mode, opts) do
      {:ok, config} ->
        configure.(@ifname, config, persist: false)
        :ok

      {:error, reason} = error ->
        Logger.error("#{__MODULE__}: #{reason}; #{@ifname} left unconfigured")
        configure.(@ifname, @unconfigured, persist: false)
        error
    end
  end

  @doc "VintageNet's configuration of `wlan0` for `mode`."
  @spec vintage_net_config(mode(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def vintage_net_config(mode, opts)

  def vintage_net_config(:join, opts) do
    case Keyword.get(opts, :networks, []) do
      [] ->
        {:ok, @unconfigured}

      networks ->
        {:ok,
         %{
           type: VintageNetWiFi,
           vintage_net_wifi: %{
             networks:
               Enum.map(networks, fn {ssid, psk} ->
                 %{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}
               end)
           },
           ipv4: %{method: :dhcp}
         }}
    end
  end

  def vintage_net_config({:hotspot, hotspot}, opts) do
    psk = Keyword.get(opts, :hotspot_psk)

    if is_binary(psk) and String.length(psk) >= @min_psk_length,
      do: {:ok, hotspot(Keyword.fetch!(hotspot, :ssid), psk)},
      else: {:error, "a hotspot needs WIFI_HOTSPOT_PSK, #{@min_psk_length} characters or more"}
  end

  def vintage_net_config(:off, _opts), do: {:ok, @unconfigured}

  defp hotspot(ssid, psk) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{mode: :ap, ssid: ssid, key_mgmt: :wpa_psk, psk: psk, frequency: @hotspot_frequency}
        ]
      },
      ipv4: %{method: :static, address: @hotspot_address, prefix_length: 24},
      dhcpd: %{
        start: {192, 168, 4, 10},
        end: {192, 168, 4, 50},
        options: %{subnet: {255, 255, 255, 0}}
      }
    }
  end

  defp vintage_net_configure(ifname, config, options),
    do: vintage_net().configure(ifname, config, options)

  defp vintage_net, do: Module.concat(@vintage_net_parts)
end
