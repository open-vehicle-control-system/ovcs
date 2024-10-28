defmodule OneDHCPD.Option do
  @moduledoc false
  import OneDHCPD.Utility

  # Message types
  @dhcpdiscover 1
  @dhcpoffer 2
  @dhcprequest 3
  @dhcpdecline 4
  @dhcpack 5
  @dhcpnak 6
  @dhcprelease 7
  @dhcpinform 8

  # DHCP options
  @dho_subnet_mask 1
  @dho_time_offset 2
  @dho_routers 3
  @dho_time_servers 4
  @dho_name_servers 5
  @dho_domain_name_servers 6
  @dho_log_servers 7
  @dho_cookie_servers 8
  @dho_lpr_servers 9
  @dho_impress_servers 10
  @dho_resource_location_servers 11
  @dho_host_name 12
  @dho_boot_size 13
  @dho_merit_dump 14
  @dho_domain_name 15
  @dho_swap_server 16
  @dho_root_path 17
  @dho_extensions_path 18
  @dho_ip_forwarding 19
  @dho_non_local_source_routing 20
  @dho_policy_filter 21
  @dho_max_dgram_reassembly 22
  @dho_default_ip_ttl 23
  @dho_path_mtu_aging_timeout 24
  @dho_path_mtu_plateau_table 25
  @dho_interface_mtu 26
  @dho_all_subnets_local 27
  @dho_broadcast_address 28
  @dho_perform_mask_discovery 29
  @dho_mask_supplier 30
  @dho_router_discovery 31
  @dho_router_solicitation_address 32
  @dho_static_routes 33
  @dho_trailer_encapsulation 34
  @dho_arp_cache_timeout 35
  @dho_ieee802_3_encapsulation 36
  @dho_default_tcp_ttl 37
  @dho_tcp_keepalive_interval 38
  @dho_tcp_keepalive_garbage 39
  @dho_nis_domain 40
  @dho_nis_servers 41
  @dho_ntp_servers 42
  @dho_vendor_encapsulated_options 43
  @dho_netbios_name_servers 44
  @dho_netbios_dd_servers 45
  @dho_netbios_node_type 46
  @dho_netbios_scope 47
  @dho_font_servers 48
  @dho_x_display_managers 49
  @dho_dhcp_requested_address 50
  @dho_dhcp_lease_time 51
  @dho_dhcp_option_overload 52
  @dho_dhcp_message_type 53
  @dho_dhcp_server_identifier 54
  @dho_dhcp_parameter_request_list 55
  @dho_dhcp_message 56
  @dho_dhcp_max_message_size 57
  @dho_dhcp_renewal_time 58
  @dho_dhcp_rebinding_time 59
  @dho_vendor_class_identifier 60
  @dho_dhcp_client_identifier 61
  @dho_nwip_domain_name 62
  # @dho_nwip_suboptions 63
  @dho_nis_plus_domain 64
  @dho_nis_plus_servers 65
  @dho_tftp_server_name 66
  @dho_bootfile_name 67
  @dho_mobile_ip_home_agents 68
  @dho_smtp_servers 69
  @dho_pop3_servers 70
  @dho_nntp_servers 71
  @dho_www_servers 72
  @dho_finger_servers 73
  @dho_irc_servers 74
  @dho_streettalk_servers 75
  @dho_stda_servers 76
  @dho_user_class 77
  @dho_fqdn 81
  @dho_dhcp_agent_options 82
  @dho_nds_servers 85
  @dho_nds_tree_name 86
  @dho_nds_context 87
  @dho_uap 98
  @dho_auto_configure 116
  @dho_name_service_search 117
  @dho_subnet_selection 118
  @dho_tftp_server_address 150

  @spec decode(byte(), binary()) :: {atom() | byte(), any()}
  def decode(@dho_subnet_mask, value), do: {:subnet_mask, decode_ip(value)}
  def decode(@dho_time_offset, value), do: {:time_offset, decode_integer(value)}
  def decode(@dho_routers, value), do: {:routers, decode_iplist(value)}
  def decode(@dho_time_servers, value), do: {:time_servers, decode_iplist(value)}
  def decode(@dho_name_servers, value), do: {:name_servers, decode_iplist(value)}
  def decode(@dho_domain_name_servers, value), do: {:domain_name_servers, decode_iplist(value)}
  def decode(@dho_log_servers, value), do: {:log_servers, decode_iplist(value)}
  def decode(@dho_cookie_servers, value), do: {:cookie_servers, decode_iplist(value)}
  def decode(@dho_lpr_servers, value), do: {:lpr_servers, decode_iplist(value)}
  def decode(@dho_impress_servers, value), do: {:impress_servers, decode_iplist(value)}

  def decode(@dho_resource_location_servers, value),
    do: {:resource_location_servers, decode_iplist(value)}

  def decode(@dho_host_name, value), do: {:host_name, value}
  def decode(@dho_boot_size, value), do: {:boot_size, decode_short(value)}
  def decode(@dho_merit_dump, value), do: {:merit_dump, value}
  def decode(@dho_domain_name, value), do: {:domain_name, value}
  def decode(@dho_swap_server, value), do: {:swap_server, decode_ip(value)}
  def decode(@dho_root_path, value), do: {:root_path, value}
  def decode(@dho_extensions_path, value), do: {:extensions_path, value}
  def decode(@dho_ip_forwarding, value), do: {:ip_forwarding, decode_byte(value)}

  def decode(@dho_non_local_source_routing, value),
    do: {:non_local_source_routing, decode_byte(value)}

  def decode(@dho_policy_filter, value), do: {:policy_filter, decode_iplist(value)}
  def decode(@dho_max_dgram_reassembly, value), do: {:max_dgram_reassembly, decode_short(value)}
  def decode(@dho_default_ip_ttl, value), do: {:default_ip_ttl, decode_byte(value)}

  def decode(@dho_path_mtu_aging_timeout, value),
    do: {:path_mtu_aging_timeout, decode_integer(value)}

  def decode(@dho_path_mtu_plateau_table, value),
    do: {:path_mtu_plateau_table, decode_integer(value)}

  def decode(@dho_interface_mtu, value), do: {:interface_mtu, decode_short(value)}
  def decode(@dho_all_subnets_local, value), do: {:all_subnets_local, decode_byte(value)}
  def decode(@dho_broadcast_address, value), do: {:broadcast_address, decode_ip(value)}

  def decode(@dho_perform_mask_discovery, value),
    do: {:perform_mask_discovery, decode_byte(value)}

  def decode(@dho_mask_supplier, value), do: {:mask_supplier, decode_byte(value)}
  def decode(@dho_router_discovery, value), do: {:router_discovery, decode_byte(value)}

  def decode(@dho_router_solicitation_address, value),
    do: {:router_solicitation_address, decode_ip(value)}

  def decode(@dho_static_routes, value), do: {:static_routes, decode_iplist(value)}
  def decode(@dho_trailer_encapsulation, value), do: {:trailer_encapsulation, decode_byte(value)}
  def decode(@dho_arp_cache_timeout, value), do: {:arp_cache_timeout, decode_integer(value)}

  def decode(@dho_ieee802_3_encapsulation, value),
    do: {:ieee802_3_encapsulation, decode_byte(value)}

  def decode(@dho_default_tcp_ttl, value), do: {:default_tcp_ttl, decode_byte(value)}

  def decode(@dho_tcp_keepalive_interval, value),
    do: {:tcp_keepalive_interval, decode_integer(value)}

  def decode(@dho_tcp_keepalive_garbage, value), do: {:tcp_keepalive_garbage, decode_byte(value)}
  def decode(@dho_nis_domain, value), do: {:nis_domain, value}
  def decode(@dho_nis_servers, value), do: {:nis_servers, decode_iplist(value)}
  def decode(@dho_ntp_servers, value), do: {:ntp_servers, decode_iplist(value)}
  def decode(@dho_tftp_server_name, value), do: {:tftp_server_name, value}
  def decode(@dho_bootfile_name, value), do: {:bootfile_name, value}

  def decode(@dho_vendor_encapsulated_options, value),
    do: {:vendor_encapsulated_options, decode_vendor(value)}

  def decode(@dho_netbios_name_servers, value), do: {:netbios_name_servers, decode_iplist(value)}
  def decode(@dho_netbios_dd_servers, value), do: {:netbios_dd_servers, decode_iplist(value)}
  def decode(@dho_netbios_node_type, value), do: {:netbios_node_type, decode_byte(value)}
  def decode(@dho_netbios_scope, value), do: {:netbios_scope, value}
  def decode(@dho_font_servers, value), do: {:font_servers, decode_iplist(value)}
  def decode(@dho_x_display_managers, value), do: {:x_display_managers, decode_iplist(value)}
  def decode(@dho_dhcp_requested_address, value), do: {:dhcp_requested_address, decode_ip(value)}
  def decode(@dho_dhcp_lease_time, value), do: {:dhcp_lease_time, decode_integer(value)}
  def decode(@dho_dhcp_option_overload, value), do: {:dhcp_option_overload, decode_byte(value)}

  def decode(@dho_dhcp_message_type, value),
    do: {:dhcp_message_type, to_message_type(decode_byte(value))}

  def decode(@dho_dhcp_server_identifier, value), do: {:dhcp_server_identifier, decode_ip(value)}
  def decode(@dho_dhcp_parameter_request_list, value), do: {:dhcp_parameter_request_list, value}
  def decode(@dho_dhcp_message, value), do: {:dhcp_message, value}
  def decode(@dho_dhcp_max_message_size, value), do: {:dhcp_max_message_size, decode_short(value)}
  def decode(@dho_dhcp_renewal_time, value), do: {:dhcp_renewal_time, decode_integer(value)}
  def decode(@dho_dhcp_rebinding_time, value), do: {:dhcp_rebinding_time, decode_integer(value)}
  def decode(@dho_vendor_class_identifier, value), do: {:vendor_class_identifier, value}
  def decode(@dho_dhcp_client_identifier, value), do: {:dhcp_client_identifier, value}
  def decode(@dho_nwip_domain_name, value), do: {:nwip_domain_name, value}
  def decode(@dho_nis_plus_domain, value), do: {:nis_plus_domain, value}
  def decode(@dho_nis_plus_servers, value), do: {:nis_plus_servers, decode_iplist(value)}

  def decode(@dho_mobile_ip_home_agents, value),
    do: {:mobile_ip_home_agents, decode_iplist(value)}

  def decode(@dho_smtp_servers, value), do: {:smtp_servers, decode_iplist(value)}
  def decode(@dho_pop3_servers, value), do: {:pop3_servers, decode_iplist(value)}
  def decode(@dho_www_servers, value), do: {:www_servers, decode_iplist(value)}
  def decode(@dho_finger_servers, value), do: {:finger_servers, decode_iplist(value)}
  def decode(@dho_irc_servers, value), do: {:irc_servers, decode_iplist(value)}
  def decode(@dho_streettalk_servers, value), do: {:streettalk_servers, decode_iplist(value)}
  def decode(@dho_stda_servers, value), do: {:stda_servers, decode_iplist(value)}
  def decode(@dho_user_class, value), do: {:user_class, value}
  def decode(@dho_fqdn, value), do: {:fqdn, value}
  def decode(@dho_dhcp_agent_options, value), do: {:dhcp_agent_options, value}
  def decode(@dho_nntp_servers, value), do: {:nntp_servers, decode_iplist(value)}
  def decode(@dho_nds_servers, value), do: {:nds_servers, decode_iplist(value)}
  def decode(@dho_nds_tree_name, value), do: {:nds_tree_name, value}
  def decode(@dho_nds_context, value), do: {:nds_context, value}
  def decode(@dho_uap, value), do: {:uap, value}
  def decode(@dho_auto_configure, value), do: {:auto_configure, decode_byte(value)}
  def decode(@dho_name_service_search, value), do: {:name_service_search, decode_shortlist(value)}
  def decode(@dho_subnet_selection, value), do: {:subnet_selection, decode_ip(value)}
  def decode(@dho_tftp_server_address, value), do: {:tftp_server_address, decode_ip(value)}
  def decode(key, value), do: {key, value}

  @spec encode(atom() | byte(), any()) :: binary()
  def encode(:subnet_mask, value), do: encode_ip(@dho_subnet_mask, value)
  def encode(:time_offset, value), do: encode_integer(@dho_time_offset, value)
  def encode(:routers, value), do: encode_iplist(@dho_routers, value)
  def encode(:time_servers, value), do: encode_iplist(@dho_time_servers, value)
  def encode(:name_servers, value), do: encode_iplist(@dho_name_servers, value)
  def encode(:nntp_servers, value), do: encode_iplist(@dho_nntp_servers, value)
  def encode(:domain_name_servers, value), do: encode_iplist(@dho_domain_name_servers, value)
  def encode(:log_servers, value), do: encode_iplist(@dho_log_servers, value)
  def encode(:cookie_servers, value), do: encode_iplist(@dho_cookie_servers, value)
  def encode(:lpr_servers, value), do: encode_iplist(@dho_lpr_servers, value)
  def encode(:impress_servers, value), do: encode_iplist(@dho_impress_servers, value)

  def encode(:resource_location_servers, value),
    do: encode_iplist(@dho_resource_location_servers, value)

  def encode(:host_name, value), do: encode_string(@dho_host_name, value)
  def encode(:boot_size, value), do: encode_short(@dho_boot_size, value)
  def encode(:merit_dump, value), do: encode_string(@dho_merit_dump, value)
  def encode(:domain_name, value), do: encode_string(@dho_domain_name, value)
  def encode(:swap_server, value), do: encode_ip(@dho_swap_server, value)
  def encode(:root_path, value), do: encode_string(@dho_root_path, value)
  def encode(:extensions_path, value), do: encode_string(@dho_extensions_path, value)
  def encode(:ip_forwarding, value), do: encode_byte(@dho_ip_forwarding, value)

  def encode(:non_local_source_routing, value),
    do: encode_byte(@dho_non_local_source_routing, value)

  def encode(:policy_filter, value), do: encode_iplist(@dho_policy_filter, value)
  def encode(:max_dgram_reassembly, value), do: encode_short(@dho_max_dgram_reassembly, value)
  def encode(:default_ip_ttl, value), do: encode_byte(@dho_default_ip_ttl, value)

  def encode(:path_mtu_aging_timeout, value),
    do: encode_integer(@dho_path_mtu_aging_timeout, value)

  def encode(:path_mtu_plateau_table, value),
    do: encode_integer(@dho_path_mtu_plateau_table, value)

  def encode(:interface_mtu, value), do: encode_short(@dho_interface_mtu, value)
  def encode(:all_subnets_local, value), do: encode_byte(@dho_all_subnets_local, value)
  def encode(:broadcast_address, value), do: encode_ip(@dho_broadcast_address, value)
  def encode(:perform_mask_discovery, value), do: encode_byte(@dho_perform_mask_discovery, value)
  def encode(:mask_supplier, value), do: encode_byte(@dho_mask_supplier, value)
  def encode(:router_discovery, value), do: encode_byte(@dho_router_discovery, value)

  def encode(:router_solicitation_address, value),
    do: encode_ip(@dho_router_solicitation_address, value)

  def encode(:static_routes, value), do: encode_iplist(@dho_static_routes, value)
  def encode(:trailer_encapsulation, value), do: encode_byte(@dho_trailer_encapsulation, value)
  def encode(:arp_cache_timeout, value), do: encode_integer(@dho_arp_cache_timeout, value)

  def encode(:ieee802_3_encapsulation, value),
    do: encode_byte(@dho_ieee802_3_encapsulation, value)

  def encode(:default_tcp_ttl, value), do: encode_byte(@dho_default_tcp_ttl, value)

  def encode(:tcp_keepalive_interval, value),
    do: encode_integer(@dho_tcp_keepalive_interval, value)

  def encode(:tcp_keepalive_garbage, value), do: encode_byte(@dho_tcp_keepalive_garbage, value)
  def encode(:nis_domain, value), do: encode_string(@dho_nis_domain, value)
  def encode(:nis_servers, value), do: encode_iplist(@dho_nis_servers, value)
  def encode(:ntp_servers, value), do: encode_iplist(@dho_ntp_servers, value)
  def encode(:tftp_server_name, value), do: encode_string(@dho_tftp_server_name, value)
  def encode(:bootfile_name, value), do: encode_string(@dho_bootfile_name, value)

  def encode(:vendor_encapsulated_options, value),
    do: encode_vendor(@dho_vendor_encapsulated_options, value)

  def encode(:netbios_name_servers, value), do: encode_iplist(@dho_netbios_name_servers, value)
  def encode(:netbios_dd_servers, value), do: encode_iplist(@dho_netbios_dd_servers, value)
  def encode(:netbios_node_type, value), do: encode_byte(@dho_netbios_node_type, value)
  def encode(:netbios_scope, value), do: encode_string(@dho_netbios_scope, value)
  def encode(:font_servers, value), do: encode_iplist(@dho_font_servers, value)
  def encode(:x_display_managers, value), do: encode_iplist(@dho_x_display_managers, value)
  def encode(:dhcp_requested_address, value), do: encode_ip(@dho_dhcp_requested_address, value)
  def encode(:dhcp_lease_time, value), do: encode_integer(@dho_dhcp_lease_time, value)
  def encode(:dhcp_option_overload, value), do: encode_byte(@dho_dhcp_option_overload, value)

  def encode(:dhcp_message_type, value),
    do: encode_byte(@dho_dhcp_message_type, from_message_type(value))

  def encode(:dhcp_server_identifier, value), do: encode_ip(@dho_dhcp_server_identifier, value)

  def encode(:dhcp_parameter_request_list, value),
    do: encode_string(@dho_dhcp_parameter_request_list, value)

  def encode(:dhcp_message, value), do: encode_string(@dho_dhcp_message, value)
  def encode(:dhcp_max_message_size, value), do: encode_short(@dho_dhcp_max_message_size, value)
  def encode(:dhcp_renewal_time, value), do: encode_integer(@dho_dhcp_renewal_time, value)
  def encode(:dhcp_rebinding_time, value), do: encode_integer(@dho_dhcp_rebinding_time, value)

  def encode(:vendor_class_identifier, value),
    do: encode_string(@dho_vendor_class_identifier, value)

  def encode(:dhcp_client_identifier, value),
    do: encode_string(@dho_dhcp_client_identifier, value)

  def encode(:nwip_domain_name, value), do: encode_string(@dho_nwip_domain_name, value)
  def encode(:nis_plus_domain, value), do: encode_string(@dho_nis_plus_domain, value)
  def encode(:nis_plus_servers, value), do: encode_iplist(@dho_nis_plus_servers, value)
  def encode(:mobile_ip_home_agents, value), do: encode_iplist(@dho_mobile_ip_home_agents, value)
  def encode(:smtp_servers, value), do: encode_iplist(@dho_smtp_servers, value)
  def encode(:pop3_servers, value), do: encode_iplist(@dho_pop3_servers, value)
  def encode(:www_servers, value), do: encode_iplist(@dho_www_servers, value)
  def encode(:finger_servers, value), do: encode_iplist(@dho_finger_servers, value)
  def encode(:irc_servers, value), do: encode_iplist(@dho_irc_servers, value)
  def encode(:streettalk_servers, value), do: encode_iplist(@dho_streettalk_servers, value)
  def encode(:stda_servers, value), do: encode_iplist(@dho_stda_servers, value)
  def encode(:user_class, value), do: encode_string(@dho_user_class, value)
  def encode(:fqdn, value), do: encode_string(@dho_fqdn, value)
  def encode(:dhcp_agent_options, value), do: encode_string(@dho_dhcp_agent_options, value)
  def encode(:nds_servers, value), do: encode_iplist(@dho_nds_servers, value)
  def encode(:nds_tree_name, value), do: encode_string(@dho_nds_tree_name, value)
  def encode(:nds_context, value), do: encode_string(@dho_nds_context, value)
  def encode(:uap, value), do: encode_string(@dho_uap, value)
  def encode(:auto_configure, value), do: encode_byte(@dho_auto_configure, value)
  def encode(:name_service_search, value), do: encode_shortlist(@dho_name_service_search, value)
  def encode(:subnet_selection, value), do: encode_ip(@dho_subnet_selection, value)
  def encode(:tftp_server_address, value), do: encode_ip(@dho_tftp_server_address, value)

  def encode(key, value) when is_integer(key) and is_binary(value) do
    <<key, byte_size(value), value::binary>>
  end

  defp to_message_type(@dhcpdiscover), do: :discover
  defp to_message_type(@dhcpoffer), do: :offer
  defp to_message_type(@dhcprequest), do: :request
  defp to_message_type(@dhcpdecline), do: :decline
  defp to_message_type(@dhcpack), do: :ack
  defp to_message_type(@dhcpnak), do: :nak
  defp to_message_type(@dhcprelease), do: :release
  defp to_message_type(@dhcpinform), do: :inform
  defp to_message_type(other), do: other

  defp from_message_type(:discover), do: @dhcpdiscover
  defp from_message_type(:offer), do: @dhcpoffer
  defp from_message_type(:request), do: @dhcprequest
  defp from_message_type(:decline), do: @dhcpdecline
  defp from_message_type(:ack), do: @dhcpack
  defp from_message_type(:nak), do: @dhcpnak
  defp from_message_type(:release), do: @dhcprelease
  defp from_message_type(:inform), do: @dhcpinform
end
