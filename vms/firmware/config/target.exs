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

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates
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
       }},
       {"wlan0",
        %{
          type: VintageNetWiFi,
          vintage_net_wifi: %{
            networks: [
              %{
                key_mgmt: :wpa_psk,
                ssid: System.get_env("WIFI_SSID"),
                psk: System.get_env("WIFI_PSK")
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

  hosts: [:hostname, "ovcs-vms"],
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

config :vms_api,
  namespace: VmsApi,
  ecto_repos: [VmsApi.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure your database
config :vms_api, VmsApi.Repo,
  database: "/data/vms_core.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Configures the endpoint
config :vms_api, VmsApiWeb.Endpoint,
  url: [host: "nerves.local"],
  http: [port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  check_origin: false,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: VmsApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: VmsApi.PubSub,
  server: true,
  live_view: [signing_salt: System.get_env("SIGNING_SALT")],
  code_reloader: false

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :vms_core,
  namespace: VmsCore,
  ecto_repos: [VmsCore.Repo],
  generators: [timestamp_type: :utc_datetime]

config :vms_core, VmsCore.Repo,
  database: "/data/vms_core_dev.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

vehicle = System.get_env("VEHICLE") || "ovcs1"

config :vms_core, :vehicle, vehicle
config :vms_core, :gear_control_module, VmsCore.Infotainment

config :cantastic,
  can_network_mappings: {
    VmsFirmware.Util.NetworkMapper,
    :can_network_mappings,
    [(System.get_env("CAN_NETWORK_MAPPINGS") || "ovcs:spi0.0,leaf_drive:spi0.1,polo_drive:spi1.0,orion_bms:spi1.1,misc:spi1.2")]
  },
  setup_can_interfaces: true,
  otp_app: :vms_core,
  priv_can_config_path: "vehicles/#{vehicle}.yml",
  enable_socketcand: true,
  socketcand_ip_interface: "wlan0"

config :vms_core, :socketcand_only, true
