defmodule VintageNetWiFi do
  @moduledoc """
  WiFi support for VintageNet

  Configurations for this technology are maps with a `:type` field set to
  `VintageNetWiFi`. The following additional fields are supported:

  * `:vintage_net_wifi` - WiFi options
  * `:ipv4` - IPv4 options. See VintageNet.IP.IPv4Config.

  To scan for WiFi networks it's sufficient to use an empty configuration and call
  the `VintageNet.scan("wlan0")`:

  ```elixir
  %{type: VintageNetWiFi}
  ```


  Here's a typical configuration for connecting to a WPA2-protected Wi-Fi network:

  ```elixir
  %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{
      mode: :infrastructure,
      networks: [%{ssid: "my_network_ssid", key_mgmt: :wpa_psk, psk: "a_passphrase_or_psk"}]
    },
    ipv4: %{method: :dhcp}
  }
  ```

  If your Wi-Fi adapter or module has support for running as an Access Point,
  then the following configuration puts it in AP mode, assigns a static IP
  address of 192.168.0.1 and gives clients IP addresses from 192.168.0.30
  to 192.168.0.254.

  ```elixir
  %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{
      mode: :ap,
      networks: [
        %{
          ssid: "test ssid",
          key_mgmt: :none
        }
      ]
    },
    ipv4: %{
      method: :static,
      address: {192, 168, 0, 1},
      prefix_length: 24
    },
    dhcpd: %{
      start: {192, 168, 0, 30},
      end: {192, 168, 0, 254}
    }
  }
  ```

  To enable verbose log messages from the `wpa_supplicant`, add `verbose: true` to the
  configuration.
  """
  @behaviour VintageNet.Technology

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP.DhcpdConfig
  alias VintageNet.IP.DnsdConfig
  alias VintageNet.IP.IPv4Config
  alias VintageNetWiFi.AccessPoint
  alias VintageNetWiFi.Cookbook
  alias VintageNetWiFi.WPA2
  alias VintageNetWiFi.WPASupplicant

  require Logger

  # These configuration keys are common to all network specifications
  # and allowed to pass through network normalization.
  @common_network_keys [
    :mode,
    :key_mgmt,
    :allowed_key_mgmt,
    :ssid,
    :bssid,
    :bssid_allowlist,
    :bssid_denylist,
    :priority,
    :scan_ssid,
    :frequency,
    :mesh_hwmp_rootmode,
    :mesh_gate_announcements,
    :ieee80211w,
    :pairwise,
    :proto
  ]

  @root_level_keys [
    :ap_scan,
    :networks,
    :bgscan,
    :passive_scan,
    :regulatory_domain,
    :user_mpm,
    :root_interface,
    :wpa_supplicant_conf_path,
    :wps_cred_processing
  ]

  @mesh_param_keys [:mesh_hwmp_rootmode, :mesh_gate_announcements]

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__} = config) do
    config
    |> normalize_wifi()
    |> IPv4Config.normalize()
    |> DhcpdConfig.normalize()
    |> DnsdConfig.normalize()
  end

  defp normalize_wifi(%{vintage_net_wifi: %{wpa_supplicant_conf: conf}} = config) do
    %{config | vintage_net_wifi: %{wpa_supplicant_conf: conf}}
  end

  defp normalize_wifi(%{vintage_net_wifi: wifi} = config) do
    new_wifi =
      wifi
      |> normalize_first_network()
      |> normalize_networks()
      |> Map.take(@root_level_keys)

    %{config | vintage_net_wifi: new_wifi}
  end

  defp normalize_wifi(_config) do
    # If wifi isn't configured, then only scanning is allowed.
    %{type: __MODULE__, vintage_net_wifi: %{networks: []}, ipv4: %{method: :disabled}}
  end

  defp normalize_first_network(%{ssid: ssid} = wifi) do
    # If user specified a standalone ssid, move it to the first spot
    # in the networks list so that networks are only stored in one place.

    Logger.warning(
      "Passing Wi-Fi network parameters outside of `:networks` for ssid '#{ssid}' is deprecated. See `VintageNet.info` for the fixed configuration."
    )

    # Rather than figure out which keys are relevant, move them all to
    # the first place in networks and let the network normalization code
    # figure it out.
    first_network = Map.drop(wifi, [:networks])

    Map.update(wifi, :networks, [first_network], &[first_network | &1])
  end

  defp normalize_first_network(wifi), do: wifi

  defp normalize_networks(%{networks: networks} = wifi) do
    # Normalize the networks and remove any dupes and empty configs
    new_networks =
      networks
      |> Enum.map(fn network -> network |> normalize_network_mode() |> normalize_network() end)
      |> Enum.filter(fn net -> net != %{} end)
      |> Enum.uniq()

    %{wifi | networks: new_networks}
  end

  defp normalize_networks(wifi) do
    # No networks specified so add an empty list
    Map.put(wifi, :networks, [])
  end

  defp normalize_network_mode(%{mode: mode} = network_config) do
    Map.put(network_config, :mode, normalized_mode_name(mode))
  end

  defp normalize_network_mode(network_config), do: Map.put(network_config, :mode, :infrastructure)

  # Convert mode names to their 802.11 operation mode name
  # :client and :host were used in vintage_net 0.6.2 and earlier
  defp normalized_mode_name(:client), do: :infrastructure
  defp normalized_mode_name(:host), do: :ap

  defp normalized_mode_name(known)
       when known in [:ap, :ibss, :infrastructure, :p2p_go, :p2p_group_formation, :mesh],
       do: known

  defp normalized_mode_name(other_mode) do
    raise ArgumentError,
          "invalid wifi mode #{inspect(other_mode)}. Specify :infrastructure, :ap, :ibss, or :mesh"
  end

  defp assert_ssid(ssid) do
    case WPA2.validate_ssid(ssid) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "Invalid WiFi network for #{inspect(ssid)}: #{inspect(reason)}"
    end
  end

  # v0.12.1 note:
  # :key_mgmt was originally restricted to be an atom, but in v0.12.1, it could be
  # a list. Since lists aren't supported in v0.12.0 and earlier, this could result
  # in a broken WiFi configuration if you revert to a firmware using the earlier
  # version.
  #
  # To fix this:
  #
  # 1. Support lists in `:key_mgmt` for the future, but normalize configs to store
  #    the list in `:allowed_key_mgmt` and have `:key_mgmt` hold the first item.
  # 2. Use `:allowed_key_mgmt` in preference to `:key_mgmt`
  # 3. Some time in the future when v0.12.0 is unlikely to be used, normalize configs
  #    to use lists for `:key_mgmt` instead of using `:allowed_key_mgmt`.
  # 4. Even farther in the future, phase out support for `:allowed_key_mgmt`.
  defp normalize_network(%{allowed_key_mgmt: keys} = network_config) when is_list(keys) do
    keys
    |> Enum.map(&extract_network_options(&1, network_config))
    |> Enum.reduce(%{}, &Map.merge/2)
    |> Map.put_new(:key_mgmt, hd(keys))
  end

  defp normalize_network(%{key_mgmt: key} = network_config) when is_atom(key) do
    extract_network_options(key, network_config)
  end

  defp normalize_network(%{key_mgmt: keys} = network_config) when is_list(keys) do
    keys
    |> Enum.map(&extract_network_options(&1, network_config))
    |> Enum.reduce(%{}, &Map.merge/2)
    |> Map.put(:allowed_key_mgmt, keys)
    |> Map.put(:key_mgmt, hd(keys))
  end

  defp normalize_network(network_config) do
    # Default to no security and try again.
    network_config
    |> Map.put(:key_mgmt, :none)
    |> normalize_network()
  end

  # WEP
  defp extract_network_options(
         :none,
         %{
           ssid: ssid,
           wep_tx_keyidx: _wep_tx_keyidx
         } = network_config
       )
       when is_binary(ssid) do
    assert_ssid(ssid)

    Map.take(
      network_config,
      [:wep_key0, :wep_key1, :wep_key2, :wep_key3, :wep_tx_keyidx | @common_network_keys]
    )
  end

  # No Security
  defp extract_network_options(:none, %{ssid: ssid} = network_config) when is_binary(ssid) do
    assert_ssid(ssid)
    Map.take(network_config, @common_network_keys)
  end

  # WPA-PSK
  defp extract_network_options(:wpa_psk, %{ssid: ssid, psk: psk} = network_config)
       when is_binary(ssid) and is_binary(psk) do
    case WPA2.to_psk(ssid, psk) do
      {:ok, real_psk} ->
        network_config
        |> Map.take([:wpa_ptk_rekey, :pairwise | @common_network_keys])
        |> Map.put(:psk, real_psk)

      {:error, reason} ->
        raise ArgumentError,
              "Invalid WPA-PSK WiFi network for #{escape_string(ssid)}: #{inspect(reason)}"
    end
  end

  # WPA-PSK-SHA256
  defp extract_network_options(:wpa_psk_sha256, %{ssid: ssid, psk: psk} = network_config)
       when is_binary(ssid) and is_binary(psk) do
    case WPA2.to_psk(ssid, psk) do
      {:ok, real_psk} ->
        network_config
        |> Map.take([:wpa_ptk_rekey | @common_network_keys])
        |> Map.put(:psk, real_psk)

      {:error, reason} ->
        raise ArgumentError,
              "Invalid WPA-PSK-SHA256 WiFi network for #{escape_string(ssid)}: #{inspect(reason)}"
    end
  end

  # SAE
  defp extract_network_options(:sae, %{ssid: ssid, sae_password: password} = network_config)
       when is_binary(ssid) and is_binary(password) do
    network_config
    |> Map.take([:sae_password | @common_network_keys])
  end

  defp extract_network_options(:sae, %{ssid: ssid, psk: password} = network_config)
       when is_binary(ssid) and is_binary(password) do
    # It's easy to specify psk instead of sae_password, so convert.
    # Note: PSK passwords have more limitations that SAE passwords, so this should be safe.
    extract_network_options(:sae, Map.put(network_config, :sae_password, password))
  end

  # WPA-EAP or IEEE8021X (TODO)
  defp extract_network_options(key_mgmt, %{ssid: ssid} = network_config)
       when key_mgmt in [:wpa_eap, :IEEE8021X] and is_binary(ssid) do
    assert_ssid(ssid)

    Map.take(network_config, [
      :anonymous_identity,
      :ca_cert,
      :ca_cert2,
      :client_cert,
      :client_cert2,
      :eap,
      :eapol_flags,
      :group,
      :identity,
      :pairwise,
      :password,
      :pcsc,
      :phase1,
      :phase2,
      :pin,
      :private_key,
      :private_key_passwd,
      :private_key2,
      :private_key2_passwd,
      :user_mpm
      | @common_network_keys
    ])
  end

  defp extract_network_options(_, %{ssid: nil} = network) do
    # This case happens when the user gets the ssid from the application
    # environment or somewhere else and that place returns `nil`. Rather
    # than crash this configuration, the expected thing seems to be to
    # drop this network so that scan-only WiFi mode is available.

    Logger.warning("Dropping network with `nil` SSID: #{inspect(network)}")
    %{}
  end

  defp extract_network_options(_, network) do
    raise ArgumentError, "don't know how to process #{inspect(network)}"
  end

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__} = config, opts) do
    tmpdir = Keyword.fetch!(opts, :tmpdir)
    regulatory_domain = Keyword.fetch!(opts, :regulatory_domain)

    wpa_supplicant_conf_path = Path.join(tmpdir, "wpa_supplicant.conf.#{ifname}")
    control_interface_dir = Path.join(tmpdir, "wpa_supplicant")
    control_interface_paths = ctrl_interface_paths(ifname, control_interface_dir, config)
    ap_mode = ap_mode?(config)
    verbose = Map.get(config, :verbose, false)

    normalized_config = normalize(config)

    files = [
      {wpa_supplicant_conf_path,
       wifi_to_supplicant_contents(
         normalized_config.vintage_net_wifi,
         control_interface_dir,
         regulatory_domain
       )}
    ]

    wpa_supplicant_options = [
      wpa_supplicant: "wpa_supplicant",
      ifname: ifname,
      wpa_supplicant_conf_path: wpa_supplicant_conf_path,
      control_path: control_interface_dir,
      ap_mode: ap_mode,
      verbose: verbose
    ]

    %RawConfig{
      ifname: ifname,
      type: __MODULE__,
      source_config: normalized_config,
      required_ifnames: required_ifnames(ifname, config),
      files: files,
      cleanup_files: control_interface_paths,
      restart_strategy: :rest_for_one,
      up_cmds: up_cmds(ifname, config),
      down_cmds: down_cmds(ifname, config),
      child_specs: [
        {WPASupplicant, wpa_supplicant_options}
      ]
    }
    |> IPv4Config.add_config(normalized_config, opts)
    |> DhcpdConfig.add_config(normalized_config, opts)
    |> DnsdConfig.add_config(normalized_config, opts)
  end

  @impl VintageNet.Technology
  def ioctl(ifname, :scan, _args) do
    WPASupplicant.scan(ifname)
  end

  def ioctl(ifname, :signal_poll, _args) do
    WPASupplicant.signal_poll(ifname)
  end

  def ioctl(ifname, :wps_pbc, _args) do
    WPASupplicant.wps_pbc(ifname)
  end

  def ioctl(_ifname, _command, _args) do
    {:error, :unsupported}
  end

  @impl VintageNet.Technology
  def check_system(_opts) do
    # TODO
    :ok
  end

  defp wifi_to_supplicant_contents(
         %{wpa_supplicant_conf: conf},
         control_interface_dir,
         _regulatory_domain
       ) do
    [into_newlines(["ctrl_interface=#{control_interface_dir}"]), conf]
    |> IO.chardata_to_string()
  end

  defp wifi_to_supplicant_contents(wifi, control_interface_dir, regulatory_domain) do
    config = [
      "ctrl_interface=#{control_interface_dir}",
      "country=#{wifi[:regulatory_domain] || regulatory_domain}",
      # By setting this to 1, we always process WPS_CRED_RECEIVED signals ourselves,
      # instead of deferring to wpa_supplicant
      "wps_cred_processing=1",
      into_config_string(wifi, :bgscan),
      into_config_string(wifi, :ap_scan),
      into_config_string(wifi, :user_mpm)
    ]

    iodata = [into_newlines(config), into_wifi_network_config(wifi)]
    IO.chardata_to_string(iodata)
  end

  defp key_mgmt_to_string(key_mgmt) do
    key_mgmt |> List.wrap() |> Enum.map_join(" ", &key_mgmt_item_to_string/1)
  end

  defp key_mgmt_item_to_string(:none), do: "NONE"
  defp key_mgmt_item_to_string(:wpa_psk), do: "WPA-PSK"
  defp key_mgmt_item_to_string(:wpa_psk_sha256), do: "WPA-PSK-SHA256"
  defp key_mgmt_item_to_string(:wpa_eap), do: "WPA-EAP"
  defp key_mgmt_item_to_string(:IEEE8021X), do: "IEEE8021X"
  defp key_mgmt_item_to_string(:sae), do: "SAE"

  defp mode_to_string(:infrastructure), do: "0"
  defp mode_to_string(:ibss), do: "1"
  defp mode_to_string(:ap), do: "2"
  defp mode_to_string(:p2p_go), do: "3"
  defp mode_to_string(:p2p_group_formation), do: "4"
  defp mode_to_string(:mesh), do: "5"

  defp bgscan_to_string(:simple), do: "\"simple\""
  defp bgscan_to_string({:simple, args}), do: "\"simple:#{args}\""
  defp bgscan_to_string(:learn), do: "\"learn\""
  defp bgscan_to_string({:learn, args}), do: "\"learn:#{args}\""

  defp pmk_to_string(n) when n in [0, 1, 2], do: Integer.to_string(n)
  defp pmk_to_string(:disabled), do: "0"
  defp pmk_to_string(:optional), do: "1"
  defp pmk_to_string(:required), do: "2"

  defp into_wifi_network_config(%{networks: networks}) when is_list(networks) do
    Enum.map(networks, &into_wifi_network_config/1)
  end

  defp into_wifi_network_config(wifi) do
    key_mgmt = if Map.has_key?(wifi, :allowed_key_mgmt), do: :allowed_key_mgmt, else: :key_mgmt

    network_config([
      # Common settings
      into_config_string(wifi, :ssid),
      into_config_string(wifi, :bssid),
      into_config_string(wifi, key_mgmt),
      into_config_string(wifi, :scan_ssid),
      into_config_string(wifi, :priority),
      into_config_string(wifi, :bssid_allowlist),
      into_config_string(wifi, :bssid_denylist),
      into_config_string(wifi, :wps_disabled),
      into_config_string(wifi, :mode),
      into_config_string(wifi, :frequency),
      into_config_string(wifi, :ieee80211w),

      # WPA-PSK settings
      into_config_string(wifi, :psk),
      into_config_string(wifi, :wpa_ptk_rekey),

      # MACSEC settings
      into_config_string(wifi, :macsec_policy),
      into_config_string(wifi, :macsec_integ_only),
      into_config_string(wifi, :macsec_replay_protect),
      into_config_string(wifi, :macsec_replay_window),
      into_config_string(wifi, :macsec_port),
      into_config_string(wifi, :mka_cak),
      into_config_string(wifi, :mka_ckn),
      into_config_string(wifi, :mka_priority),

      # EAP settings
      into_config_string(wifi, :identity),
      into_config_string(wifi, :anonymous_identity),
      into_config_string(wifi, :password),
      into_config_string(wifi, :pairwise),
      into_config_string(wifi, :group),
      into_config_string(wifi, :group_mgmt),
      into_config_string(wifi, :eap),
      into_config_string(wifi, :eapol_flags),
      into_config_string(wifi, :phase1),
      into_config_string(wifi, :phase2),
      into_config_string(wifi, :fragment_size),
      into_config_string(wifi, :ocsp),
      into_config_string(wifi, :openssl_ciphers),
      into_config_string(wifi, :erp),

      # SAE settings
      into_config_string(wifi, :sae_password),

      # TODO:
      # These parts are files.
      # They should probably be added to the `files` part
      # of raw_config
      into_config_string(wifi, :ca_cert),
      into_config_string(wifi, :ca_cert2),
      into_config_string(wifi, :dh_file),
      into_config_string(wifi, :dh_file2),
      into_config_string(wifi, :client_cert),
      into_config_string(wifi, :client_cert2),
      into_config_string(wifi, :private_key),
      into_config_string(wifi, :private_key2),
      into_config_string(wifi, :private_key_passwd),
      into_config_string(wifi, :private_key2_passwd),
      into_config_string(wifi, :pac_file),

      # WEP Settings
      into_config_string(wifi, :auth_alg),
      into_config_string(wifi, :wep_key0),
      into_config_string(wifi, :wep_key1),
      into_config_string(wifi, :wep_key2),
      into_config_string(wifi, :wep_key3),
      into_config_string(wifi, :wep_tx_keyidx),

      # SIM Settings
      into_config_string(wifi, :pin),
      into_config_string(wifi, :pcsc)
    ])
  end

  defp into_config_string(wifi, opt_key) do
    case Map.get(wifi, opt_key) do
      nil -> nil
      opt -> wifi_opt_to_config_string(wifi, opt_key, opt)
    end
  end

  defp wifi_opt_to_config_string(_wifi, :ssid, ssid) do
    process_ssid = ssid |> escape_string |> do_wpa_supplicant_ssid_hack()
    "ssid=#{process_ssid}"
  end

  defp wifi_opt_to_config_string(_wifi, :bssid, bssid) do
    "bssid=#{bssid}"
  end

  defp wifi_opt_to_config_string(_wifi, :psk, psk) do
    "psk=#{psk}"
  end

  defp wifi_opt_to_config_string(_wifi, :wpa_ptk_rekey, wpa_ptk_rekey) do
    "wpa_ptk_rekey=#{wpa_ptk_rekey}"
  end

  defp wifi_opt_to_config_string(_wifi, key_mgmt_key, key_mgmt)
       when key_mgmt_key in [:key_mgmt, :allowed_key_mgmt] do
    "key_mgmt=#{key_mgmt_to_string(key_mgmt)}"
  end

  defp wifi_opt_to_config_string(_wifi, :mode, mode) do
    "mode=#{mode_to_string(mode)}"
  end

  defp wifi_opt_to_config_string(_wifi, :ap_scan, value) do
    "ap_scan=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :scan_ssid, value) do
    "scan_ssid=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :priority, value) do
    "priority=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :frequency, value) do
    "frequency=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :identity, value) do
    "identity=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :anonymous_identity, value) do
    "anonymous_identity=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :password, value) do
    "password=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :phase1, value) do
    "phase1=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :phase2, value) do
    "phase2=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :pairwise, value) do
    "pairwise=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :group, value) do
    "group=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :eap, value) do
    "eap=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :eapol_flags, value) do
    "eapol_flags=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :ca_cert, value) do
    "ca_cert=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :ca_cert2, value) do
    "ca_cert2=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :client_cert, value) do
    "client_cert=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :client_cert2, value) do
    "client_cert2=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :private_key, value) do
    "private_key=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :private_key2, value) do
    "private_key2=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :private_key_passwd, value) do
    "private_key_passwd=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :private_key2_passwd, value) do
    "private_key2_passwd=#{escape_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :pin, value) do
    "pin=#{inspect(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :wep_tx_keyidx, value) do
    "wep_tx_keyidx=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :wep_key0, value) do
    "wep_key0=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :wep_key1, value) do
    "wep_key1=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :wep_key2, value) do
    "wep_key2=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :wep_key3, value) do
    "wep_key3=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :pcsc, value) do
    "pcsc=#{inspect(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :bssid_denylist, value) do
    "bssid_blacklist=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :bssid_allowlist, value) do
    "bssid_whitelist=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :bgscan, value) do
    "bgscan=#{bgscan_to_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :passive_scan, value) do
    "passive_scan=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :user_mpm, value) do
    "user_mpm=#{value}"
  end

  defp wifi_opt_to_config_string(_wifi, :sae_password, value) do
    "sae_password=\"#{value}\""
  end

  defp wifi_opt_to_config_string(_wifi, :ieee80211w, value) do
    "ieee80211w=#{pmk_to_string(value)}"
  end

  defp wifi_opt_to_config_string(_wifi, :wps_cred_processing, value) do
    "wps_cred_processing=#{value}"
  end

  defp network_config(config) do
    ["network={", "\n", into_newlines(config), "}", "\n"]
  end

  defp into_newlines(config) do
    Enum.map(config, fn
      nil -> []
      conf -> [conf, "\n"]
    end)
  end

  defp ap_mode?(%{vintage_net_wifi: %{networks: [%{mode: mode}]}}) when mode in [:ap, :ibss],
    do: true

  defp ap_mode?(_config), do: false

  # if mesh mode, the interface name is not a real interface yet. it needs to be brought up
  defp required_ifnames(_ifname, %{
         vintage_net_wifi: %{root_interface: root_interface, networks: [%{mode: :mesh}]}
       }) do
    [root_interface]
  end

  defp required_ifnames(_ifname, %{vintage_net_wifi: %{networks: [%{mode: :mesh}]}}) do
    raise ArgumentError, "`root_interface` is a required key when specifying `mode: :mesh`"
  end

  # any other mode just relies on the actual interface name
  defp required_ifnames(ifname, _) do
    [ifname]
  end

  defp up_cmds(ifname, %{vintage_net_wifi: %{root_interface: root_interface} = config}) do
    mesh_mode = Application.app_dir(:vintage_net_wifi, ["priv", "mesh_mode"])
    mesh_param = Application.app_dir(:vintage_net_wifi, ["priv", "mesh_param"])
    mesh_params = Map.take(config, @mesh_param_keys)

    mesh_params_up_cmds =
      Enum.map(mesh_params, fn
        {param, value} when is_integer(value) ->
          {:run, mesh_param, [ifname, param, value]}
      end)

    [
      {:run, mesh_mode, [root_interface, ifname, "add"]},
      {:fun,
       fn ->
         Process.sleep(1000)
       end}
    ] ++ mesh_params_up_cmds
  end

  defp up_cmds(_, _), do: []

  defp down_cmds(ifname, %{vintage_net_wifi: %{root_interface: root_interface}}) do
    mesh_mode = Application.app_dir(:vintage_net_wifi, ["priv", "mesh_mode"])

    [
      {:run, mesh_mode, [root_interface, ifname, "del"]},
      {:fun,
       fn ->
         Process.sleep(1000)
       end}
    ]
  end

  defp down_cmds(_, _), do: []

  defp ctrl_interface_paths(ifname, dir, %{vintage_net_wifi: %{networks: [%{mode: mode}]}})
       when mode in [:ap, :ibss] do
    # Some WiFi drivers expose P2P interfaces and those should be cleaned up too.
    [Path.join(dir, "p2p-dev-#{ifname}"), Path.join(dir, ifname)]
  end

  defp ctrl_interface_paths(ifname, dir, _),
    do: [Path.join(dir, ifname)]

  @doc """
  Configure WiFi using the most common settings

  If your network requires a password (WPA2 PSK and WPA3 SAE networks):

  ```
  iex> VintageNetWiFi.quick_configure("ssid", "password")
  :ok
  ```

  If you're connecting to an open network, don't pass the password. Keep in
  mind that if you're at a cafe or other location that has a captive portal,
  `VintageNetWiFi` isn't smart enough to bypass it.

  ```
  iex> VintageNetWiFi.quick_configure("open_wifi_ssid")
  :ok
  ```

  Then run `VintageNet.info` to see when the network connects. If you're
  writing a program, run `VintageNet.get(["interface", "wlan0", "connection"])`
  to get the connection status or subscribe to that property for change
  notifications.

  If you're on an enterprise network or use static IP addresses or need any
  other special configuration handling, you'll need to call
  `VintageNet.configure/3` instead. See `VintageNetWiFi.Cookbook` for help with
  creating configurations or manually construct the configuration map.

  > #### WiFi Authentication {: .info}
  >
  > VintageNetWiFi doesn't know whether the WiFi hardware you're using fully
  > supports WPA3 authentication. To avoid hard to understand errors,
  > `quick_configure/2` defaults to WPA2. If you have hardware that supports
  > WPA3 and would like to use WPA2/WPA3 generic configurations, update your
  > `config.exs` to:
  >
  > ```
  > config :vintage_net_wifi, :quick_configure, &VintageNetWiFi.Cookbook.generic/2
  > ```
  """
  @spec quick_configure(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def quick_configure(ssid, passphrase \\ nil)

  def quick_configure(ssid, empty_passphrase)
      when is_nil(empty_passphrase) or empty_passphrase == "" do
    with {:ok, config} <- Cookbook.open_wifi(ssid) do
      VintageNet.configure("wlan0", config)
    end
  end

  def quick_configure(ssid, passphrase) do
    cookbook_strategy =
      Application.get_env(:vintage_net_wifi, :quick_configure, &Cookbook.wpa_psk/2)

    with {:ok, config} <- cookbook_strategy.(ssid, passphrase) do
      VintageNet.configure("wlan0", config)
    end
  end

  @doc """
  Create a WiFi network config string for use in a QR Code

  A QR Code created from the string returned by this function is scannable by
  almost any smartphone to allow easy access to a Wi-Fi network. The user only
  needs to agree to a prompt rather than enter credentials manually.

  See https://github.com/zxing/zxing/wiki/Barcode-Contents#wi-fi-network-config-android-ios-11
  for more format details.
  """
  @type qr_options() :: [hidden: boolean(), type: :WPA | :WEP | :nopass]
  @spec qr_string(String.t(), String.t(), qr_options()) :: String.t()
  def qr_string(ssid, password, opts \\ []) do
    default_type = if password != "", do: :WPA, else: :nopass
    type = opts[:type] || default_type
    hidden = opts[:hidden] || false

    [
      "WIFI:",
      mecard_param(?S, ssid),
      if(type != :nopass, do: [mecard_param(?T, type), mecard_param(?P, password)], else: []),
      if(hidden, do: mecard_param(?H, hidden), else: []),
      ";"
    ]
    |> IO.chardata_to_string()
  end

  defp mecard_param(param, value), do: [param, ?:, mecard_escape(value), ?;]

  defp mecard_escape(input) when is_atom(input), do: to_string(input)

  defp mecard_escape(input) when is_binary(input) do
    case Base.decode16(input, case: :mixed) do
      {:ok, _} -> [?", input, ?"]
      :error -> mecard_escape_generic(input)
    end
  end

  defp mecard_escape_generic(input) do
    escape_chars = [?#, ?\\, ?;, ?,, ?", ?:]

    for <<c <- input>>, into: "" do
      if c in escape_chars, do: <<"\\", c>>, else: <<c>>
    end
  end

  @doc """
  Convenience function to scan for access points

  This function initiates a scan, waits, and then returns all of the discovered
  access points. It's intended for quickly seeing what's around.

  If you'd like to use this in a program, but want to display access point options
  as they're found, here's how to do it:

  ```elixir
  VintageNet.subscribe(["interface", "wlan0", "wifi", "access_points"])
  VintageNet.scan("wlan0")
  ```

  Then wait for messages. They'll be of the form:

  ```elixir
  {VintageNet, ["interface", "wlan0", "wifi", "access_points"], old_value, new_value, meta}
  ```

  Both `old_value` and `new_value` will be lists of access points. You'll need
  call `VintageNet.scan/1` every 30 seconds or so to repeat the scan across all
  WiFi channels. See also `VintageNetWiFi.summarize_access_points/1` to get an
  easier to manage list of access points for presentation to users.
  """
  @spec quick_scan(non_neg_integer()) :: [AccessPoint.t()]
  def quick_scan(wait_time_ms \\ 2_000) do
    :ok = ioctl("wlan0", :scan, [])

    # Wait a little for the access points to come in
    Process.sleep(wait_time_ms)

    VintageNet.get(["interface", "wlan0", "wifi", "access_points"])
    |> summarize_access_points()
  end

  @doc """
  Summarize access point lists

  This function summarizes a list of access points, such as those returned from
  `quick_scan/1` or via calls to `VintageNet.scan/1` checking the
  `["interface", "wlan0", "wifi", "access_points"]` property.  The summary
  provides a list that most people are used to seeing when looking for access
  points. It does the following:

  * When the same SSID is found on multiple channels, it picks the one with the
    best signal and removes the others.
  * Filter out SSIDs used by mesh routers and other devices that wouldn't work
  * Sort SSIDs by signal strength
  """
  @spec summarize_access_points([AccessPoint.t()]) :: [AccessPoint.t()]
  def summarize_access_points(access_points) do
    access_points
    |> Enum.filter(&usable_ssid?/1)
    |> Enum.sort_by(fn %{signal_percent: p} -> p end, :desc)
    |> Enum.uniq_by(fn %{ssid: s} -> s end)
  end

  defp usable_ssid?(access_point) do
    ssid = access_point.ssid

    not String.contains?(ssid, "\0") and
      String.trim(ssid) != ""
  end

  @doc """
  Quick way to receive WiFi credentials via WPS PBC

  Call this function with a long enough timeout for you to press the WPS button
  on your access point.  The WiFi gets configured as soon as the WPS
  credentials are received.

  ```elixir
  VintageNetWiFi.quick_wps(60_000)
  # Press WPS button on AP
  :ok
  ```
  """
  @spec quick_wps(non_neg_integer()) :: {:ok, map()} | {:error, String.t()}
  def quick_wps(timeout \\ 60_000) do
    with :ok <- VintageNet.configure("wlan0", %{type: VintageNetWiFi}),
         # Give it some time for the wlan interface to restart
         Process.sleep(1000),
         {:ok, _} <- WPASupplicant.wps_pbc("wlan0"),
         {:ok, credentials} <- get_wps_credentials(now(), timeout) do
      configure_wps(credentials)
    end
  end

  defp get_wps_credentials(start_time, timeout) do
    case VintageNet.get(["interface", "wlan0", "wifi", "wps_credentials"]) do
      nil ->
        unless now() > start_time + timeout do
          Process.sleep(1000)
          get_wps_credentials(start_time, timeout)
        end

      other ->
        other
    end
  end

  defp configure_wps(%{credential: %{ssid: ssid, network_key: psk}}) do
    quick_configure(ssid, psk)
  end

  defp configure_wps(other) do
    {:error, "Don't know how to configure #{inspect(other)}"}
  end

  defp now() do
    System.monotonic_time(:millisecond)
  end

  defp escape_string(value) when is_binary(value) do
    # Use inspect since the Elixir API that escapes non-printable characters is
    # currently private.
    inspect(value, binaries: :as_strings)
  end

  defp do_wpa_supplicant_ssid_hack("\"" <> str) when byte_size(str) > 33 do
    # Work around wpa_supplicant complaining about SSIDs that are too
    # long when their unescaped length is greater than 32 characters
    Logger.warning("Trimming unusual SSID to avoid wpa_supplicant issue. Check config.")
    trimmed = binary_part(str, 0, 32) |> trim_orphan_backslash()
    "\"" <> trimmed <> "\""
  end

  defp do_wpa_supplicant_ssid_hack(str), do: str

  defp trim_orphan_backslash(<<s::30-bytes, second_last, ?\\>>) when second_last != ?\\ do
    <<s::binary, second_last>>
  end

  defp trim_orphan_backslash(s), do: s

  @doc """
  Helper for checking whether a WiFi configuration has a network configured

  This is useful for checking whether a WiFi configuration is just good for
  scanning for WiFi networks or whether it actually could connect to another
  computer.

  Returns `false` if the configuration isn't a VintageNetWiFi one or if no
  networks were specified.

  To test an `ifname` has a network configured, run:

  ```
  VintageNet.get_configuration() |> network_configured?()
  ```
  """
  @spec network_configured?(map()) :: boolean()
  def network_configured?(wlan_config) when wlan_config == %{type: VintageNetWiFi}, do: false
  def network_configured?(%{vintage_net_wifi: %{networks: []}}), do: false
  def network_configured?(%{vintage_net_wifi: %{networks: [_ | _]}}), do: true
  def network_configured?(_), do: false

  @doc """
  Experimental API for getting WiFi driver capabilities

  This queries the `wpa_supplicant` and driver to see what it supports. It's
  useful for seeing whether WPA3, 5 GHz, and other things are supported. The
  results aren't currently processed.
  """
  @spec capabilities(VintageNet.ifname()) :: map()
  def capabilities(ifname) do
    keys = [
      :key_mgmt,
      :modes,
      :channels,
      :pairwise,
      :group,
      :group_mgmt,
      :proto,
      :freq,
      :sae,
      :beacon_prot,
      :eap,
      :auth_alg,
      :tdls,
      :erp,
      :fips,
      :acs,
      :fils,
      :multibss,
      :dpp,
      :ocv
    ]

    keys |> Enum.map(&get_capability(ifname, &1)) |> Map.new()
  end

  defp get_capability(ifname, key) do
    case WPASupplicant.raw_command(ifname, "GET_CAPABILITY #{key}") do
      {:ok, "FAIL\n"} -> {key, :unknown}
      {:ok, result} -> {key, result}
      _ -> {key, :error}
    end
  end
end
