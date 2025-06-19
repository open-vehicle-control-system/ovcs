import Config

if config_env() in [:dev, :test, :prod] do
  for path <- [".env.exs", ".env.#{config_env()}.exs"] do
    path = Path.join(__DIR__, "..") |> Path.join("config") |> Path.join(path) |> Path.expand()
    if File.exists?(path), do: import_config(path)
  end
end

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without real-time clocks.
config :nerves, :erlinit, update_clock: true

vehicle      = (System.get_env("VEHICLE") || "OVCS1")
vehicle_path = Macro.underscore(vehicle)
vehicle_host = "#{vehicle_path |> String.replace("_", "-")}-ros-bridge"

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: System.get_env("AUTHORIZED_SSH_KEYS") |> String.split(",")

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }
    },
    # {"wlan0",
    #   %{
    #     type: VintageNetWiFi,
    #     vintage_net_wifi: %{
    #       networks: [
    #         %{
    #           mode: :ap,
    #           ssid: "test ssid",
    #           key_mgmt: :none
    #         }
    #       ]
    #     },
    #     ipv4: %{
    #       method: :static,
    #       address: "192.168.24.1",
    #       netmask: "255.255.255.0"
    #     },
    #     dhcpd: %{
    #       start: "192.168.24.2",
    #       end: "192.168.24.10",
    #       options: %{
    #         dns: ["1.1.1.1", "1.0.0.1"],
    #         subnet: "255.255.255.0",
    #         router: ["192.168.24.1"]
    #       }
    #     }
    #   }
    # },
    # # {"wlan1", %{
    # #   type: VintageNetWiFi,
    # #   vintage_net_wifi: %{
    # #     networks: [
    # #       %{
    # #         key_mgmt: :wpa_psk,
    # #         ssid: System.get_env("WIFI_SSID"),
    # #         psk: System.get_env("WIFI_PSK")
    # #       }
    # #     ]
    # #   },
    # #   ipv4: %{method: :dhcp}
    # # }},
    # # {"wlan1", %{
    # #   type: VintageNetWiFi,
    # #   vintage_net_wifi: %{
    # #     networks: [
    # #       %{
    # #         key_mgmt: :wpa_psk,
    # #         ssid: System.get_env("WIFI_SSID"),
    # #         psk: System.get_env("WIFI_PSK")
    # #       }
    # #     ]
    # #   },
    # #   ipv4: %{method: :dhcp}
    # # }},
    # # { "br0", %{
    # #   type: VintageNetBridge,
    # #   ipv4: %{method: :dhcp},
    # #   vintage_net_bridge: %{
    # #     interfaces: ["eth0", "wlan0"]
    # #   }
    # # }}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, vehicle_host],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"

config :cantastic,
  setup_can_interfaces: true,
  can_network_mappings: [{"ovcs", "can0"}]

config :nerves, :erlinit, hostname_pattern: vehicle_host
config :nerves, :erlinit, env: "LD_LIBRARY_PATH=/opt/ros/jazzy/lib;ROS_DISTRO=jazzy;RMW_IMPLEMENTATION=rmw_cyclonedds_cpp;CYCLONEDDS_URI=file:///etc/cyclonedds.xml"
config :nerves, :erlinit, ctty: "ttyAMA10"

config :ros_bridge_firmware, zenoh_endpoint_ip: "172.16.0.91"
