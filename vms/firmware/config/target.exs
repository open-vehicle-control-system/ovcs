import Config

if config_env() in [:dev, :test, :prod] do
  for path <- [".env.exs", ".env.#{config_env()}.exs"] do
    path = Path.join(__DIR__, "..") |> Path.join("config") |> Path.join(path) |> Path.expand()
    if File.exists?(path), do: import_config(path)
  end
end

vehicle_name =
  System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"

vehicle_dir = Macro.underscore(vehicle_name)
vehicle_host = "#{vehicle_dir |> String.replace("_", "-")}-vms"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Advance the system clock on devices without real-time clocks.
config :nerves, :erlinit, update_clock: true, hostname_pattern: vehicle_host

config :nerves_ssh,
  authorized_keys: (System.get_env("AUTHORIZED_SSH_KEYS") || "") |> String.split(",", trim: true)

config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }}
  ]

config :mdns_lite,
  hosts: [:hostname, vehicle_host],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

# Phoenix / Ecto — firmware paths (on-device SQLite) and mDNS-based host.
config :vms_api,
  namespace: VmsApi,
  ecto_repos: [VmsApi.Repo],
  generators: [timestamp_type: :utc_datetime]

config :vms_api, VmsApi.Repo,
  database: "/data/vms_core.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :vms_api, VmsApiWeb.Endpoint,
  url: [host: vehicle_host],
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

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

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

config :vms_core, :socketcand_only, System.get_env("SOCKETCAND_ONLY") == "true"
