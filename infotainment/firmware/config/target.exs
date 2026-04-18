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
vehicle_host = "#{vehicle_dir |> String.replace("_", "-")}-infotainment"

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

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
config :infotainment_api, InfotainmentApi.Repo,
  database: "/data/infotainment_api/infotainment_api.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :infotainment_api,
  ecto_repos: [InfotainmentApi.Repo],
  generators: [timestamp_type: :utc_datetime]

config :infotainment_api, InfotainmentApiWeb.Endpoint,
  url: [host: vehicle_host],
  http: [port: 4001],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  check_origin: false,
  server: true,
  code_reloader: false,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: InfotainmentApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: InfotainmentApi.PubSub,
  live_view: [signing_salt: System.get_env("SIGNING_SALT")]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: :debug

config :phoenix, :json_library, Jason
