import Config

vehicle_name =
  System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"

vehicle_dir = Macro.underscore(vehicle_name)
vehicle_host = "#{vehicle_dir |> String.replace("_", "-")}-vms"

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

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Advance the system clock on devices without real-time clocks.
# `ctty: "ttyS0"` mirrors BEAM/IEx onto the UART so boot crashes are
# visible on a serial console (kept on tty1 by default for HDMI users).
# `mount: "/dev/mmcblk0p3:/data:..."` overrides where the OVCS Nerves
# system mounts the writable application partition. The system's own
# `etc/erlinit.config` mounts it at `/root`, but the rest of the
# codebase (and every upstream Nerves library — NervesSSH, nerves_time,
# etc.) assumes the standard `/data` convention. We prepend a `/data`
# mount so erlinit mounts it there first; the system's `/root` mount
# line still gets emitted but fails harmlessly (device already mounted)
# and erlinit logs and continues. Once `ovcs_base_can_system_rpi4`'s
# erlinit.config is updated upstream, this override can come out.
config :nerves, :erlinit,
  update_clock: true,
  hostname_pattern: vehicle_host,
  ctty: "ttyS0",
  mount: "/dev/mmcblk0p3:/data:f2fs:nodev:"

config :nerves_ssh,
  authorized_keys: (System.get_env("AUTHORIZED_SSH_KEYS") || "") |> String.split(",", trim: true),
  # NervesSSH 1.3.0's hand-rolled ed25519 host key generation returns a
  # `{:ed_pri, :ed25519, pub, priv}` tuple (per a comment in its source
  # about an older Erlang limitation). OTP 27's :ssh expects ed25519
  # keys as `:ECPrivateKey` records and rejects the older tuple with
  # "No host key available". The on-disk PEM file NervesSSH writes is
  # actually fine — `:ssh_file.host_key/2` parses it correctly. So we
  # bypass NervesSSH's `key_cb` for `:ssh.daemon` and let OTP's default
  # `:ssh_file` callback read the host key + authorized_keys from disk
  # (NervesSSH writes both to system_dir / user_dir respectively).
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
config :vms_api,
  namespace: VmsApi,
  generators: [timestamp_type: :utc_datetime]

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
