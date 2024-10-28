defmodule VintageNetWiFi.WPASupplicantDecoder do
  @moduledoc false
  alias VintageNetWiFi.WPSData

  require Logger

  @doc """
  Decode notifications from the wpa_supplicant
  """
  @spec decode_notification(binary()) ::
          {:event, String.t()}
          | {:event, String.t(), any()}
          | {:event, String.t(), any(), any()}
          | {:event, String.t(), any(), any(), any()}
          | {:info, String.t()}
          | {:interactive, String.t(), any(), any()}
  def decode_notification(<<"CTRL-REQ-", rest::binary>>) do
    [field, net_id, text] = String.split(rest, "-", parts: 3, trim: true)
    {:interactive, "CTRL-REQ-" <> field, String.to_integer(net_id), text}
  end

  def decode_notification(<<"CTRL-EVENT-BSS-ADDED", rest::binary>>) do
    [entry_id, bssid] = String.split(rest, " ", trim: true)
    {:event, "CTRL-EVENT-BSS-ADDED", String.to_integer(entry_id), bssid}
  end

  def decode_notification(<<"CTRL-EVENT-BSS-REMOVED", rest::binary>>) do
    [entry_id, bssid] = String.split(rest, " ", trim: true)
    {:event, "CTRL-EVENT-BSS-REMOVED", String.to_integer(entry_id), bssid}
  end

  # This message is just not shaped the same as others for some reason.
  def decode_notification(<<"CTRL-EVENT-CONNECTED", rest::binary>>) do
    ["-", "Connection", "to", bssid, status | info] = String.split(rest)

    info =
      Regex.scan(~r(\w+=[a-zA-Z0-9:\"_]+), Enum.join(info, " "))
      |> Map.new(fn [str] ->
        [key, val] = String.split(str, "=")
        {key, unescape_string(val)}
      end)

    {:event, "CTRL-EVENT-CONNECTED", bssid, status, info}
  end

  def decode_notification(<<"CTRL-EVENT-DISCONNECTED", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-DISCONNECTED", rest)
  end

  # "CTRL-EVENT-REGDOM-CHANGE init=CORE"
  def decode_notification(<<"CTRL-EVENT-REGDOM-CHANGE", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-REGDOM-CHANGE", rest)
  end

  # "CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16"
  def decode_notification(<<"CTRL-EVENT-ASSOC-REJECT", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-ASSOC-REJECT", rest)
  end

  # "CTRL-EVENT-SSID-TEMP-DISABLED id=1 ssid=\"FarmbotConnect\" auth_failures=1 duration=10 reason=CONN_FAILED"
  def decode_notification(<<"CTRL-EVENT-SSID-TEMP-DISABLED", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-SSID-TEMP-DISABLED", rest)
  end

  # "CTRL-EVENT-SUBNET-STATUS-UPDATE status=0"
  def decode_notification(<<"CTRL-EVENT-SUBNET-STATUS-UPDATE", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-SUBNET-STATUS-UPDATE", rest)
  end

  # CTRL-EVENT-SSID-REENABLED id=1 ssid=\"FarmbotConnect\""
  def decode_notification(<<"CTRL-EVENT-SSID-REENABLED", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-SSID-REENABLED", rest)
  end

  # "CTRL-EVENT-EAP-PEER-CERT depth=0 subject='/C=US/ST=California/L=San Luis Obispo/O=FarmBot Inc/CN=Connor Rigby/emailAddress=connor@farmbot.io' hash=ae7b11dc19b0ed3497540ac551d9730fd86380b3da9d494bb27cb8f2bda8fbd6"
  def decode_notification(<<"CTRL-EVENT-EAP-PEER-CERT ", rest::binary>>) do
    info = eap_peer_cert_decode(rest)
    {:event, "CTRL-EVENT-EAP-PEER-CERT", info}
  end

  def decode_notification(<<"CTRL-EVENT-EAP-STATUS", rest::binary>>) do
    info =
      Regex.scan(~r/\w+=(["'])(?:(?=(\\?))\2.)*?\1/, rest)
      |> Map.new(fn [str | _] ->
        [key, val] = String.split(str, "=", parts: 2)
        {key, unquote_string(val)}
      end)

    {:event, "CTRL-EVENT-EAP-STATUS", info}
  end

  def decode_notification(<<"CTRL-EVENT-EAP-FAILURE", rest::binary>>) do
    {:event, "CTRL-EVENT-EAP-FAILURE", String.trim(rest)}
  end

  def decode_notification(<<"CTRL-EVENT-EAP-METHOD", rest::binary>>) do
    {:event, "CTRL-EVENT-EAP-METHOD", String.trim(rest)}
  end

  def decode_notification(<<"CTRL-EVENT-EAP-PROPOSED-METHOD", rest::binary>>) do
    decode_kv_notification("CTRL-EVENT-EAP-PROPOSED-METHOD", rest)
  end

  def decode_notification(<<"CTRL-EVENT-", _type::binary>> = event) do
    {:event, String.trim_trailing(event)}
  end

  def decode_notification(<<"WPS-CRED-RECEIVED ", rest::binary>>) do
    {:event, "WPS-CRED-RECEIVED", WPSData.decode(rest)}
  end

  def decode_notification(<<"WPS-", _type::binary>> = event) do
    {:event, String.trim_trailing(event)}
  end

  def decode_notification(<<"AP-STA-CONNECTED ", mac::binary>>) do
    {:event, "AP-STA-CONNECTED", String.trim_trailing(mac)}
  end

  def decode_notification(<<"AP-STA-DISCONNECTED ", mac::binary>>) do
    {:event, "AP-STA-DISCONNECTED", String.trim_trailing(mac)}
  end

  # MESH-PEER-DISCONNECTED 00:00:00:00:00:00
  def decode_notification(<<"MESH-PEER-DISCONNECTED ", mac::binary>>) do
    {:event, "MESH-PEER-DISCONNECTED", String.trim_trailing(mac)}
  end

  # MESH-PEER-CONNECTED 00:00:00:00:00:00
  def decode_notification(<<"MESH-PEER-CONNECTED ", mac::binary>>) do
    {:event, "MESH-PEER-CONNECTED", String.trim_trailing(mac)}
  end

  # MESH-GROUP-STARTED ssid=\"my-mesh\" id=1
  def decode_notification(<<"MESH-GROUP-STARTED ", rest::binary>>) do
    decode_kv_notification("MESH-GROUP-STARTED", rest)
  end

  # MESH-GROUP-REMOVED mesh0
  def decode_notification(<<"MESH-GROUP-REMOVED ", ifname::binary>>) do
    {:event, "MESH-GROUP-REMOVED", String.trim_trailing(ifname)}
  end

  # MESH-SAE-AUTH-FAILURE addr=00:00:00:00:00:00
  def decode_notification(<<"MESH-SAE-AUTH-FAILURE ", rest::binary>>) do
    decode_kv_notification("MESH-SAE-AUTH-FAILURE", rest)
  end

  # MESH-SAE-AUTH-BLOCKED addr=00:00:00:00:00:00 duration=5
  def decode_notification(<<"MESH-SAE-AUTH-BLOCKED ", rest::binary>>) do
    decode_kv_notification("MESH-SAE-AUTH-BLOCKED", rest)
  end

  def decode_notification(string) do
    {:info, String.trim_trailing(string)}
  end

  defp eap_peer_cert_decode(
         binary,
         state \\ %{key?: true, in_quote?: false, key: <<>>, value: <<>>},
         acc \\ %{}
       )

  defp eap_peer_cert_decode(<<"=", rest::binary>>, %{key?: true} = state, acc) do
    eap_peer_cert_decode(rest, %{state | key?: false}, acc)
  end

  defp eap_peer_cert_decode(<<"\'", rest::binary>>, %{key?: false, in_quote?: false} = state, acc) do
    eap_peer_cert_decode(rest, %{state | in_quote?: true, value: state.value}, acc)
  end

  defp eap_peer_cert_decode(<<"\'", rest::binary>>, %{key?: false, in_quote?: true} = state, acc) do
    eap_peer_cert_decode(rest, %{state | in_quote?: false, value: state.value}, acc)
  end

  defp eap_peer_cert_decode(<<" ", rest::binary>>, %{key?: false, in_quote?: false} = state, acc) do
    eap_peer_cert_decode(
      rest,
      %{key?: true, in_quote?: false, key: <<>>, value: <<>>},
      Map.put(acc, state.key, String.trim(state.value))
    )
  end

  defp eap_peer_cert_decode(<<char::1-bytes, rest::binary>>, %{key?: true} = state, acc) do
    eap_peer_cert_decode(rest, %{state | key: state.key <> char}, acc)
  end

  defp eap_peer_cert_decode(<<char::1-bytes, rest::binary>>, %{key?: false} = state, acc) do
    eap_peer_cert_decode(rest, %{state | value: state.value <> char}, acc)
  end

  defp eap_peer_cert_decode(<<>>, state, acc) do
    Map.put(acc, state.key, String.trim(state.value))
  end

  defp decode_kv_notification(event, rest) do
    info =
      Regex.scan(~r(\w+=[\S*]+), rest)
      |> Map.new(fn [str] ->
        str = String.replace(str, "\'", "")
        [key, val] = String.split(str, "=", parts: 2)

        clean_val = val |> unquote_string() |> unescape_string()
        {key, clean_val}
      end)

    case Map.pop(info, "bssid") do
      {nil, _original} -> {:event, event, info}
      {bssid, new_info} -> {:event, event, bssid, new_info}
    end
  end

  @doc """
  Decode a key-value response from the wpa_supplicant
  """
  @spec decode_kv_response(String.t()) :: %{String.t() => String.t()}
  def decode_kv_response(resp) do
    resp
    |> String.split("\n", trim: true)
    |> decode_kv_pairs()
  end

  defp decode_kv_pairs(pairs) do
    Enum.reduce(pairs, %{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          clean_value = value |> String.trim_trailing() |> unescape_string()

          Map.put(acc, key, clean_value)

        _ ->
          # Skip
          acc
      end
    end)
  end

  defp unquote_string(<<"\"", _::binary>> = msg), do: String.trim(msg, "\"")
  defp unquote_string(<<"\'", _::binary>> = msg), do: String.trim(msg, "\'")
  defp unquote_string(other), do: other

  defp unescape_string(string) do
    unescape_string(string, [])
    |> Enum.reverse()
    |> :erlang.list_to_binary()
  end

  defp unescape_string("", acc), do: acc

  defp unescape_string(<<?\\, ?x, hex::binary-size(2), rest::binary>>, acc) do
    value = String.to_integer(hex, 16)
    unescape_string(rest, [value | acc])
  end

  defp unescape_string(<<other, rest::binary>>, acc) do
    unescape_string(rest, [other | acc])
  end

  @doc """
  Parse WiFi access point flags

  See `wpa_supplicant/ctl_iface.c` and search for `flags=` for where this gets
  created.
  """
  @spec parse_flags(String.t() | nil) :: [VintageNetWiFi.AccessPoint.flag()]
  def parse_flags(str) when is_binary(str) do
    flag_strings = String.split(str, ["]", "["], trim: true)

    # Old code depends on these atoms in the flags
    legacy_flags = Enum.flat_map(flag_strings, &parse_legacy_flag/1)

    # New code should look at these
    new_flags = Enum.flat_map(flag_strings, &parse_flag/1)

    legacy_flags ++ new_flags
  end

  def parse_flags(nil), do: []

  # Old code depends on these
  defp parse_legacy_flag("WPA2-PSK-CCMP"), do: [:wpa2_psk_ccmp]
  defp parse_legacy_flag("WPA2-EAP-CCMP"), do: [:wpa2_eap_ccmp]
  defp parse_legacy_flag("WPA2-EAP-CCMP+TKIP"), do: [:wpa2_eap_ccmp_tkip]
  defp parse_legacy_flag("WPA2-PSK-CCMP+TKIP"), do: [:wpa2_psk_ccmp_tkip]
  defp parse_legacy_flag("WPA2-PSK+SAE-CCMP"), do: [:wpa2_psk_sae_ccmp]
  defp parse_legacy_flag("WPA2-SAE-CCMP"), do: [:wpa2_sae_ccmp]
  defp parse_legacy_flag("WPA2--CCMP"), do: [:wpa2_ccmp]
  defp parse_legacy_flag("WPA-PSK-CCMP"), do: [:wpa_psk_ccmp]
  defp parse_legacy_flag("WPA-PSK-CCMP+TKIP"), do: [:wpa_psk_ccmp_tkip]
  defp parse_legacy_flag("WPA-EAP-CCMP"), do: [:wpa_eap_ccmp]
  defp parse_legacy_flag("WPA-EAP-CCMP+TKIP"), do: [:wpa_eap_ccmp_tkip]
  defp parse_legacy_flag("RSN--CCMP"), do: [:rsn_ccmp]
  defp parse_legacy_flag(_), do: []

  # This is a recursive descent parse for parsing each flag
  defp parse_flag(str) do
    str |> parse_flag([]) |> Enum.reverse()
  end

  # Parse the proto-key_mgmt-cipher style flags
  defp parse_flag("WPA-" <> rest, flags), do: parse_key_mgmt(rest, [:wpa | flags])
  defp parse_flag("WPA2-" <> rest, flags), do: parse_key_mgmt(rest, [:wpa2 | flags])
  defp parse_flag("RSN-" <> rest, flags), do: parse_key_mgmt(rest, [:rsn | flags])
  defp parse_flag("OSEN-" <> rest, flags), do: parse_key_mgmt(rest, [:osen | flags])

  # Parse standalone flags
  defp parse_flag("OWE-TRANS", flags), do: [:owe_trans | flags]
  defp parse_flag("OWE-TRANS-OPEN", flags), do: [:owe_trans_open | flags]
  defp parse_flag("WEP", flags), do: [:wep | flags]
  defp parse_flag("MESH", flags), do: [:mesh | flags]
  defp parse_flag("DMG", flags), do: [:dmg | flags]
  defp parse_flag("IBSS", flags), do: [:ibss | flags]
  defp parse_flag("ESS", flags), do: [:ess | flags]
  defp parse_flag("PBSS", flags), do: [:pbss | flags]
  defp parse_flag("P2P", flags), do: [:p2p | flags]
  defp parse_flag("HS20", flags), do: [:hs20 | flags]
  defp parse_flag("FILS", flags), do: [:fils | flags]
  defp parse_flag("FST", flags), do: [:fst | flags]
  defp parse_flag("UTF-8", flags), do: [:utf8 | flags]
  defp parse_flag("WPS", flags), do: [:wps | flags]
  defp parse_flag("SAE-H2E", flags), do: [:sae_h2e | flags]
  defp parse_flag("SAE-PK", flags), do: [:sae_pk | flags]

  defp parse_flag(other, flags) do
    Logger.warning("[wpa_supplicant] Unknown flag: #{other}")
    flags
  end

  # key_mgmt=one or more of the following separated by + signs
  #   EAP,PSK,None,SAE,FT/EAP,FT/PSK,FT/SAE,EAP-SHA256,PSK-SHA256,EAP-SUITE-B,EAP-SUITE-B-192,
  #   FILS-SHA256,FILS-SHA384,FT-FILS-SHA256,FT-FILS-SHA384,OWE,DPP,OSEN,""
  #
  # IMPORTANT: These are tested in order, so it's critical that longer strings
  #            are placed before any prefixes they contain!!!
  defp parse_key_mgmt("EAP-SHA256" <> rest, flags),
    do: parse_key_mgmt(rest, [:eap_sha256 | flags])

  defp parse_key_mgmt("EAP-SUITE-B-192" <> rest, flags),
    do: parse_key_mgmt(rest, [:eap_suite_b_192 | flags])

  defp parse_key_mgmt("EAP-SUITE-B" <> rest, flags),
    do: parse_key_mgmt(rest, [:eap_suite_b | flags])

  defp parse_key_mgmt("PSK-SHA256" <> rest, flags),
    do: parse_key_mgmt(rest, [:psk_sha256 | flags])

  defp parse_key_mgmt("FILS-SHA256" <> rest, flags),
    do: parse_key_mgmt(rest, [:fils_sha256 | flags])

  defp parse_key_mgmt("FILS-SHA384" <> rest, flags),
    do: parse_key_mgmt(rest, [:fils_sha384 | flags])

  defp parse_key_mgmt("FT-FILS-SHA256" <> rest, flags),
    do: parse_key_mgmt(rest, [:ft_fils_sha256 | flags])

  defp parse_key_mgmt("FT-FILS-SHA384" <> rest, flags),
    do: parse_key_mgmt(rest, [:ft_fils_sha384 | flags])

  defp parse_key_mgmt("None" <> rest, flags), do: parse_key_mgmt(rest, flags)
  defp parse_key_mgmt("EAP" <> rest, flags), do: parse_key_mgmt(rest, [:eap | flags])
  defp parse_key_mgmt("PSK" <> rest, flags), do: parse_key_mgmt(rest, [:psk | flags])
  defp parse_key_mgmt("SAE" <> rest, flags), do: parse_key_mgmt(rest, [:sae | flags])
  defp parse_key_mgmt("FT/EAP" <> rest, flags), do: parse_key_mgmt(rest, [:ft_eap | flags])
  defp parse_key_mgmt("FT/PSK" <> rest, flags), do: parse_key_mgmt(rest, [:ft_psk | flags])
  defp parse_key_mgmt("FT/SAE" <> rest, flags), do: parse_key_mgmt(rest, [:ft_sae | flags])
  defp parse_key_mgmt("OWE" <> rest, flags), do: parse_key_mgmt(rest, [:owe | flags])
  defp parse_key_mgmt("DPP" <> rest, flags), do: parse_key_mgmt(rest, [:dpp | flags])
  defp parse_key_mgmt("OSEN" <> rest, flags), do: parse_key_mgmt(rest, [:osen | flags])
  defp parse_key_mgmt("-" <> rest, flags), do: parse_cipher(rest, flags)
  defp parse_key_mgmt("+" <> rest, flags), do: parse_key_mgmt(rest, flags)
  defp parse_key_mgmt("", flags), do: flags

  defp parse_key_mgmt(other, flags) do
    Logger.warning("[wpa_supplicant] Ignoring unknown key_mgmt flag: #{other}")
    flags
  end

  # See wpa_write_ciphers() for cipher list
  # ciphers=CCMP-256,GCMP-256,CCMP,GCMP,TKIP,AES-128-CMAC,BIP-GMAC-128,BIP-GMAC-256,BIP-CMAC-256,NONE,""
  defp parse_cipher("CCMP-256" <> rest, flags), do: parse_cipher(rest, [:ccmp256 | flags])
  defp parse_cipher("CCMP" <> rest, flags), do: parse_cipher(rest, [:ccmp | flags])
  defp parse_cipher("GCMP-256" <> rest, flags), do: parse_cipher(rest, [:gcmp256 | flags])
  defp parse_cipher("GCMP" <> rest, flags), do: parse_cipher(rest, [:gcmp | flags])
  defp parse_cipher("TKIP" <> rest, flags), do: parse_cipher(rest, [:tkip | flags])
  defp parse_cipher("AES-128-CMAC" <> rest, flags), do: parse_cipher(rest, [:aes128_cmac | flags])
  defp parse_cipher("BIP-GMAC-128" <> rest, flags), do: parse_cipher(rest, [:bip_gmac128 | flags])
  defp parse_cipher("BIP-GMAC-256" <> rest, flags), do: parse_cipher(rest, [:bip_gmac256 | flags])
  defp parse_cipher("NONE" <> rest, flags), do: parse_cipher(rest, flags)
  defp parse_cipher("+" <> rest, flags), do: parse_cipher(rest, flags)
  defp parse_cipher("", flags), do: flags
  defp parse_cipher("-preauth", flags), do: [:preauth | flags]

  defp parse_cipher(other, flags) do
    Logger.warning("[wpa_supplicant] Ignoring unknown cipher flag: #{other}")
    flags
  end
end
