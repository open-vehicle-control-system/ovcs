import Config

vehicle_name =
  System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"

vehicle_dir = Macro.underscore(vehicle_name)
vehicle_host = "#{vehicle_dir |> String.replace("_", "-")}-vision"

# Per-vehicle environment overrides (SSH keys, Wi-Fi creds, Phoenix
# secrets, Zenoh router), shared by every firmware of one vehicle.
# Gitignored.
if config_env() in [:dev, :test, :prod] do
  env_files = [".env.exs", ".env.#{config_env()}.exs"]

  for filename <- env_files do
    abs = Path.expand("../../../vehicles/#{vehicle_dir}/#{filename}", __DIR__)
    if File.exists?(abs), do: import_config(abs)
  end

  # A firmware built without the env file boots with generated secrets,
  # no SSH keys, a reset Wi-Fi list and no Zenoh router, so the build
  # fails instead. CI only checks that firmware compiles (GitHub sets
  # CI=true).
  unless Enum.any?(env_files, fn filename ->
           Path.expand("../../../vehicles/#{vehicle_dir}/#{filename}", __DIR__)
           |> File.exists?()
         end) do
    if System.get_env("CI") == "true" do
      IO.warn("no .env.exs for vehicle #{inspect(vehicle_dir)}: building with defaults (CI).", [])
    else
      raise "no .env.exs for vehicle #{inspect(vehicle_dir)}: a firmware built without it " <>
              "has generated secrets, no SSH keys (you would be locked out), a reset " <>
              "Wi-Fi list, and ZENOH_ENDPOINT_IP=127.0.0.1 (the vision unit reaches no " <>
              "router). Copy vehicles/#{vehicle_dir}/.env.exs.example to .env.exs and fill " <>
              "it in. Set CI=true to build with defaults anyway."
    end
  end
end

# The device has no SECRET_KEY_BASE in its env: it is baked in below.
if config_env() == :prod and System.get_env("SECRET_KEY_BASE") in [nil, ""] do
  raise """
  environment variable SECRET_KEY_BASE is missing.
  You can generate one by calling: mix phx.gen.secret
  """
end

config :logger, backends: [RingLogger]

# `:nerves_hub_link` boots before the main app so a unit whose
# application crashes at startup stays reachable for an OTA fix.
config :shoehorn, init: [:nerves_runtime, :nerves_pack, :nerves_hub_link]

# The system's erlinit mounts the application partition at `/root`;
# NervesSSH, nerves_time and the rest of the codebase expect `/data`.
config :nerves, :erlinit,
  update_clock: true,
  hostname_pattern: vehicle_host,
  mount: "/dev/mmcblk0p3:/data:f2fs:nodev:"

config :nerves_ssh,
  authorized_keys: (System.get_env("AUTHORIZED_SSH_KEYS") || "") |> String.split(",", trim: true),
  # See vms/firmware/config/target.exs (NervesSSH 1.3.0 / OTP 27
  # ed25519 host key format).
  daemon_option_overrides: [key_cb: :ssh_file]

# NervesHub OTA updates, as in vms/firmware/config/target.exs: off
# unless the vehicle's `.env.exs` sets `NERVES_HUB_HOST`.
case System.get_env("NERVES_HUB_HOST") do
  blank when blank in [nil, ""] ->
    config :nerves_hub_link, connect: false

  nerves_hub_host ->
    config :nerves_hub_link,
      host: nerves_hub_host,
      shared_secret: [
        product_key: System.fetch_env!("NERVES_HUB_PRODUCT_KEY"),
        product_secret: System.fetch_env!("NERVES_HUB_PRODUCT_SECRET")
      ],
      remote_iex: true
end

# `.env.exs` only sets the build host's env, so the router IP is baked
# into the app config for the vehicle's vision composer to read.
config :vision_core, zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1")

# The Zenoh router is the vehicle's compute node, which also serves the
# vehicle network's time (`ntp` in compose/compute).
ntp_pool = ["0.pool.ntp.org", "1.pool.ntp.org", "2.pool.ntp.org", "3.pool.ntp.org"]

config :nerves_time,
  servers:
    (case System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1") do
       "127.0.0.1" -> ntp_pool
       router -> [router | ntp_pool]
     end)

# `WIFI_NETWORKS` is an Elixir list literal of `{ssid, psk}` tuples from
# the vehicle's `.env.exs`. Deps are not compiled when Mix evaluates this
# file, so it is parsed with `Code.eval_string/1`.
wifi_networks =
  case System.get_env("WIFI_NETWORKS") do
    blank when blank in [nil, ""] ->
      []

    src ->
      {parsed, _} = Code.eval_string(src)

      Enum.map(parsed, fn {ssid, psk} ->
        %{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}
      end)
  end

wlan0_config =
  case wifi_networks do
    [] ->
      []

    networks ->
      [
        {"wlan0",
         %{
           type: VintageNetWiFi,
           vintage_net_wifi: %{networks: networks},
           ipv4: %{method: :dhcp}
         }}
      ]
  end

config :vintage_net,
  regulatory_domain: "00",
  additional_name_servers: [{127, 0, 0, 53}],
  config:
    [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :dhcp}
       }}
    ] ++ wlan0_config

# The DNS bridge answers `.local` queries for Erlang's resolver, which
# has no mDNS support of its own. See the "DNS Bridge configuration"
# section of the mdns_lite README.
config :mdns_lite,
  hosts: [:hostname, vehicle_host],
  ttl: 120,
  dns_bridge_enabled: true,
  dns_bridge_ip: {127, 0, 0, 53},
  dns_bridge_port: 53,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

# Start Erlang distribution as `nerves@<hostname>.local` so
# `OvcsBus.Cluster` can reach the vehicle's other firmwares. See
# `OvcsBus.Distribution`.
config :ovcs_bus, :distribution, domain: "local"

config :vision_api, VisionApiWeb.Endpoint,
  url: [host: vehicle_host],
  http: [port: 4100],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  check_origin: false,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: VisionApiWeb.ErrorJSON], layout: false],
  pubsub_server: VisionApi.PubSub,
  server: true,
  code_reloader: false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
