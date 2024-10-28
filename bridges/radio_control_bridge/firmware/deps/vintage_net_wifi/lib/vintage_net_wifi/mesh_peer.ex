defmodule VintageNetWiFi.MeshPeer do
  @moduledoc """
  Information about a WiFi mesh peer

  This is a superset of the fields available on VintageNetWiFi.AccessPoint.
  """
  alias VintageNetWiFi.{AccessPoint, Utils, WPASupplicantDecoder}
  alias VintageNetWiFi.MeshPeer.{Capabilities, FormationInformation}

  defstruct [
    :bssid,
    :frequency,
    :band,
    :channel,
    :signal_dbm,
    :signal_percent,
    :flags,
    :ssid,
    :active_path_selection_metric_id,
    :active_path_selection_protocol_id,
    :age,
    :authentication_protocol_id,
    :beacon_int,
    :bss_basic_rate_set,
    :capabilities,
    :congestion_control_mode_id,
    :est_throughput,
    :id,
    :mesh_capability,
    :mesh_formation_info,
    :mesh_id,
    :noise_dbm,
    :quality,
    :snr,
    :synchronization_method_id
  ]

  @type t :: %__MODULE__{
          active_path_selection_metric_id: non_neg_integer(),
          active_path_selection_protocol_id: non_neg_integer(),
          age: non_neg_integer(),
          authentication_protocol_id: non_neg_integer(),
          band: AccessPoint.band(),
          beacon_int: non_neg_integer(),
          bss_basic_rate_set: String.t(),
          bssid: String.t(),
          capabilities: integer(),
          channel: non_neg_integer(),
          congestion_control_mode_id: non_neg_integer(),
          est_throughput: non_neg_integer(),
          flags: [AccessPoint.flag()],
          frequency: non_neg_integer(),
          id: non_neg_integer(),
          mesh_capability: Capabilities.t(),
          mesh_formation_info: FormationInformation.t(),
          mesh_id: String.t(),
          noise_dbm: integer(),
          quality: integer(),
          signal_dbm: integer(),
          signal_percent: 0..100,
          snr: non_neg_integer(),
          ssid: String.t(),
          synchronization_method_id: non_neg_integer()
        }

  @doc """
  Create a new MeshPeer struct
  """
  @spec new(keyword() | map()) :: t()
  def new(peer) do
    frequency = string_to_integer(peer["freq"])
    signal_dbm = string_to_integer(peer["level"])
    flags = WPASupplicantDecoder.parse_flags(peer["flags"])
    ssid = peer["ssid"]
    bssid = peer["bssid"]
    info = Utils.frequency_info(frequency)

    active_path_selection_metric_id = string_to_integer(peer["active_path_selection_metric_id"])

    active_path_selection_protocol_id =
      string_to_integer(peer["active_path_selection_protocol_id"])

    age = string_to_integer(peer["age"])
    authentication_protocol_id = string_to_integer(peer["authentication_protocol_id"])
    beacon_int = string_to_integer(peer["beacon_int"])
    bss_basic_rate_set = peer["bss_basic_rate_set"]
    capabilities = string_to_integer(peer["capabilities"])
    congestion_control_mode_id = string_to_integer(peer["congestion_control_mode_id"])
    est_throughput = string_to_integer(peer["est_throughput"])
    id = string_to_integer(peer["id"])

    mesh_capability =
      Capabilities.decode_capabilities(<<string_to_integer(peer["mesh_capability"])>>)

    mesh_formation_info =
      FormationInformation.decode_formation_information(
        <<string_to_integer(peer["mesh_formation_info"])>>
      )

    mesh_id = peer["mesh_id"]
    noise_dbm = string_to_integer(peer["noise"])
    quality = string_to_integer(peer["qual"])
    snr = string_to_integer(peer["snr"])
    synchronization_method_id = string_to_integer(peer["synchronization_method_id"])

    %__MODULE__{
      bssid: bssid,
      frequency: frequency,
      band: info.band,
      channel: info.channel,
      signal_dbm: signal_dbm,
      signal_percent: info.dbm_to_percent.(signal_dbm),
      flags: flags,
      ssid: ssid,
      active_path_selection_metric_id: active_path_selection_metric_id,
      active_path_selection_protocol_id: active_path_selection_protocol_id,
      age: age,
      authentication_protocol_id: authentication_protocol_id,
      beacon_int: beacon_int,
      bss_basic_rate_set: bss_basic_rate_set,
      capabilities: capabilities,
      congestion_control_mode_id: congestion_control_mode_id,
      est_throughput: est_throughput,
      id: id,
      mesh_capability: mesh_capability,
      mesh_formation_info: mesh_formation_info,
      mesh_id: mesh_id,
      noise_dbm: noise_dbm,
      quality: quality,
      snr: snr,
      synchronization_method_id: synchronization_method_id
    }
  end

  defp string_to_integer("0x" <> str) do
    String.to_integer(str, 16)
  end

  defp string_to_integer(str) do
    String.to_integer(str)
  end
end
