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
      `192.168.4.50`. The passphrase is 8 to 63 printable ASCII characters,
      as WPA2 takes it (`valid_passphrase?/1`).
    * `:off` — unconfigured.

  A mode it cannot apply, or one VintageNet refuses, leaves `wlan0`
  unconfigured and is logged; it never raises.

  Options: `:mode` (`:join`), `:networks`, `:hotspot_psk`, and
  `:configure`, for tests, a function of the interface, its configuration
  and VintageNet's options.

  `OvcsVehicle.Application` starts it once VintageNet runs, when the
  firmware sets `:ovcs_vehicle, :wifi_mode`.
  """

  use Task, restart: :temporary

  require Logger

  @ifname "wlan0"

  # Resolved at runtime, as in `OvcsVehicle.ClockSync`: this library does
  # not depend on VintageNet, and the firmwares bring it.
  @vintage_net_parts [:VintageNet]

  @unconfigured %{type: VintageNet.Technology.Null}
  # Channel 6, on 2.4 GHz, which every phone supports.
  @hotspot_frequency 2437
  @hotspot_address {192, 168, 4, 1}

  @type mode :: :join | {:hotspot, [ssid: String.t()]} | :off

  @doc "Applies `opts[:mode]` once, as `configure/2` does."
  def start_link(opts),
    do: Task.start_link(fn -> configure(Keyword.get(opts, :mode, :join), opts) end)

  @doc """
  Applies `mode` to `wlan0` without saving it; a mode it refuses leaves
  `wlan0` unconfigured, and that or VintageNet's refusal is logged.
  """
  @spec configure(mode(), keyword()) :: :ok | {:error, String.t()}
  def configure(mode, opts \\ []) do
    configure = Keyword.get(opts, :configure, &vintage_net_configure/3)

    case vintage_net_config(mode, opts) do
      {:ok, config} ->
        configure.(@ifname, config, persist: false) |> logged()

      {:error, reason} = error ->
        Logger.error("#{__MODULE__}: #{reason}; #{@ifname} left unconfigured")
        configure.(@ifname, @unconfigured, persist: false)
        error
    end
  end

  @doc "Whether WPA2 takes `psk` as a passphrase: 8 to 63 printable ASCII characters."
  @spec valid_passphrase?(term()) :: boolean()
  def valid_passphrase?(psk), do: is_binary(psk) and psk =~ ~r/\A[\x20-\x7E]{8,63}\z/

  defp logged({:error, reason} = error) do
    Logger.error(
      "#{__MODULE__}: VintageNet refused #{@ifname}'s configuration: #{inspect(reason)}"
    )

    error
  end

  defp logged(_ok), do: :ok

  @doc "VintageNet's configuration of `wlan0` for `mode`."
  @spec vintage_net_config(mode(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def vintage_net_config(mode, opts)

  def vintage_net_config(:join, opts) do
    networks = Keyword.get(opts, :networks, [])

    cond do
      networks == [] ->
        {:ok, @unconfigured}

      Enum.all?(networks, &match?({ssid, psk} when is_binary(ssid) and is_binary(psk), &1)) ->
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

      true ->
        {:error, "WIFI_NETWORKS holds an entry that is not an {ssid, psk} pair of strings"}
    end
  end

  def vintage_net_config({:hotspot, hotspot}, opts) when is_list(hotspot) do
    ssid = Keyword.get(hotspot, :ssid)
    psk = Keyword.get(opts, :hotspot_psk)

    cond do
      not is_binary(ssid) ->
        {:error, "a hotspot needs an ssid: {:hotspot, ssid: \"name\"}"}

      not valid_passphrase?(psk) ->
        {:error, "a hotspot needs WIFI_HOTSPOT_PSK, 8 to 63 printable ASCII characters"}

      true ->
        {:ok, hotspot(ssid, psk)}
    end
  end

  def vintage_net_config(:off, _opts), do: {:ok, @unconfigured}

  def vintage_net_config(mode, _opts),
    do: {:error, "unknown Wi-Fi mode #{inspect(mode)}: :join, {:hotspot, ssid: \"name\"} or :off"}

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
