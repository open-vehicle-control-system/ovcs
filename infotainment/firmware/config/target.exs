import Config

vehicle_name =
  System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"

vehicle_dir = Macro.underscore(vehicle_name)
vehicle_host = "#{vehicle_dir |> String.replace("_", "-")}-infotainment"

# Per-vehicle environment overrides (SSH keys, Wi-Fi creds, Phoenix
# secrets). Lives at `vehicles/<vehicle_dir>/.env.exs` so the same
# values are picked up by every firmware (vms, infotainment, bridges)
# of one vehicle. Gitignored.
if config_env() in [:dev, :test, :prod] do
  for filename <- [".env.exs", ".env.#{config_env()}.exs"] do
    abs = Path.expand("../../../vehicles/#{vehicle_dir}/#{filename}", __DIR__)
    if File.exists?(abs), do: import_config(abs)
  end
end

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# See vms/firmware/config/target.exs for why the mount target is
# overridden to `/data` (the OVCS Nerves system's own erlinit.config
# mounts at `/root`, but the codebase + upstream Nerves libraries
# assume `/data`).
config :nerves, :erlinit,
  update_clock: true,
  hostname_pattern: vehicle_host,
  mount: "/dev/mmcblk0p3:/data:f2fs:nodev:"

config :nerves_ssh,
  authorized_keys: (System.get_env("AUTHORIZED_SSH_KEYS") || "") |> String.split(",", trim: true),
  # See vms/firmware/config/target.exs for why we override key_cb to
  # :ssh_file (NervesSSH 1.3.0 / OTP 27 ed25519 tuple-format bug).
  daemon_option_overrides: [key_cb: :ssh_file]

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

# Phoenix endpoint — firmware host (mDNS-based).
config :infotainment_api,
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
