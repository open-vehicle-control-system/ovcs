import Config

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

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

keys =
  [
    Path.join([System.user_home!(), ".ssh", "id_rsa.pub"]),
    Path.join([System.user_home!(), ".ssh", "id_ecdsa.pub"]),
    Path.join([System.user_home!(), ".ssh", "id_ed25519.pub"])
  ]
  |> Enum.filter(&File.exists?/1)

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

    config :nerves_ssh,
    authorized_keys: [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICF1a6Pj8MCGEGsoDx6t0IWcKbXrQ3Jr/QSRXRVk80q2 thibault@spin42.com",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7cQdQbGsUqnCr6ko6QpdOobbhqWU1zXg4adNvjoZMuH5OLV2uzL9cH5FzmSNhh6GwOm/LXKNVefrWR/L2T6H5LPgT0oubaaIcMfvB0q+Ldv6zlSJ/7mWzQeItA2yV/uqoWrUkHH01IsYaXhwtztyVjIBJW9F0Ol7HOPd02GU5yUibyj+2Ptv8caHdfEEwuODF11mtBvygpbCQKQJxZYuVs1f1GoNkRWBydVi5Ub1QqxyxnYmX14/6ijADsnap90LLfplyEpL1hPt6y4agzzeoF47OhSeQ/TowcfKNRx/o+N0XKhOsmzw2UCDSvd5k31eAnTONsy3lUWyyew8NbrGQIoNqKsiq2vKB1JGgPJIuCLd3gPsl3UmMNH07m/g+/b5Rr68jXjgtcxSTBL/h+1qQEbKc2A/f5KplZj/gRkYrl8YYEi6+ypi/jWij8LLQZ7u8xCYoWJURyGDFFSN/pA3E6MmLGzMqLfO8yfmumUYuOYFsSX55tthyLRr9f4H5u3s= mlainez@marc-framework",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCV66oOqkXp3FDYpjWU8FLIon+sCS9qalAzN4zt90gAfjkF05TqYqAnLfRL59xkdgTdIhVr4DfjB5yDgDXG1ZTdFCsNZQPiJR6SFWEGUbc8gTCN+OoQcvpHndU/SeeU1SM/XsnLkQSf68q43PjPHZdujkJaerjwW7T9eJEGULTNNWizNnC72NEq7LVaQ7NFXs+i5v1mcCK4xr6m62WiHbYhBzXcfWFlZTFUeeLIkR1R4OBCh2WwVLrO2Y3fVSkIUYPMusMtkzgfp55WuhNSVQuWFp7TTt6UPpJCtLvKay8xzmaKR/BnSkltElDBkQByFlUrf4QSwlKUR0B+31v6nPyoK/fyC2v/720uqPdvPWYjl9wjlJnyIKIDBNPSb9ehYWfLmZTMA5x5dzdGYvm1sabBlCIWXZi1Gje5uNg+hz37AAdp0vFPwtG0yq3rhoK2bqdW/Qk7bNaxnIi30Raw9SHR2+nOqZkVmb8NC+JJJ3Vhzy61aUilPMopMur8akVmaQU= loo@loo-fmwk"
    ]

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
     }},
     {"wlan0",
      %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{
          networks: [
            %{
              key_mgmt: :wpa_psk,
              ssid: "Area42-Guest",
              psk: "bemyguest"
            }
          ]
       },
       ipv4: %{method: :dhcp}
     }
    }
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
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
