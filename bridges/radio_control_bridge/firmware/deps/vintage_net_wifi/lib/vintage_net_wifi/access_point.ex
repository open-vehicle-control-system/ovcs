defmodule VintageNetWiFi.AccessPoint do
  @moduledoc """
  Information about a WiFi access point

  * `:bssid` - a unique address for the access point
  * `:flags` - a list of flags describing properties on the access point
  * `:frequency` - the access point's frequency in MHz
  * `:signal_dbm` - the signal strength in dBm
  * `:ssid` - the access point's name
  """
  alias VintageNetWiFi.Utils

  @typedoc """
  Access point flags

  These flags generally describe the security supported by an access point, but do contain some other details. They're
  directly passed on from `wpa_supplicant` reports.
  """
  @type flag ::
          :ccmp
          | :eap
          | :ess
          | :ibss
          | :mesh
          | :p2p
          | :psk
          | :rsn_ccmp
          | :sae
          | :tkip
          | :wep
          | :wpa
          | :wpa2
          | :wps
          | old_flag()

  @typedoc """
  Old-style access point flags

  Early on with `vintage_net_wifi`, flags were not broken up and returned in a list. The WPA3 support made this approach unmaintainable, but these are
  kept to avoid breaking code. New code should avoid using these.
  """
  @type old_flag ::
          :wpa2_psk_ccmp
          | :wpa2_eap_ccmp
          | :wpa2_eap_ccmp_tkip
          | :wpa2_psk_ccmp_tkip
          | :wpa2_psk_sae_ccmp
          | :wpa2_sae_ccmp
          | :wpa2_ccmp
          | :wpa_psk_ccmp
          | :wpa_psk_ccmp_tkip
          | :wpa_eap_ccmp
          | :wpa_eap_ccmp_tkip

  @type band :: :wifi_2_4_ghz | :wifi_5_ghz | :unknown

  defstruct [:bssid, :frequency, :band, :channel, :signal_dbm, :signal_percent, :flags, :ssid]

  @type t :: %__MODULE__{
          bssid: String.t(),
          frequency: non_neg_integer(),
          band: band(),
          channel: non_neg_integer(),
          signal_dbm: integer(),
          signal_percent: 0..100,
          flags: [flag()],
          ssid: String.t()
        }

  @doc """
  Create an AccessPoint when only the BSSID is known
  """
  @spec new(any) :: VintageNetWiFi.AccessPoint.t()
  def new(bssid) do
    %__MODULE__{
      bssid: bssid,
      frequency: 0,
      band: :unknown,
      channel: 0,
      signal_dbm: -99,
      signal_percent: 0,
      flags: [],
      ssid: ""
    }
  end

  @doc """
  Create a new AccessPoint with all of the information
  """
  @spec new(String.t(), String.t(), non_neg_integer(), integer(), [flag()]) ::
          VintageNetWiFi.AccessPoint.t()
  def new(bssid, ssid, frequency, signal_dbm, flags) do
    info = Utils.frequency_info(frequency)

    %__MODULE__{
      bssid: bssid,
      frequency: frequency,
      band: info.band,
      channel: info.channel,
      signal_dbm: signal_dbm,
      signal_percent: info.dbm_to_percent.(signal_dbm),
      flags: flags,
      ssid: ssid
    }
  end
end
