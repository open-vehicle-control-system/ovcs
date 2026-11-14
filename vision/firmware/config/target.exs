import Config

vehicle_name =
  System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"

vehicle_directory = Macro.underscore(vehicle_name)
vehicle_host = "#{vehicle_directory |> String.replace("_", "-")}-vision"

# Per-vehicle environment overrides (SSH keys, Wi-Fi creds, Phoenix
# secrets, Zenoh router), shared by every firmware of one vehicle.
# Gitignored.
if config_env() in [:dev, :test, :prod] do
  env_files = [".env.exs", ".env.#{config_env()}.exs"]

  for filename <- env_files do
    env_file_path = Path.expand("../../../vehicles/#{vehicle_directory}/#{filename}", __DIR__)
    if File.exists?(env_file_path), do: import_config(env_file_path)
  end

  # A firmware built without the env file boots with generated secrets,
  # no SSH keys, a reset Wi-Fi list and no Zenoh router, so the build
  # fails instead. CI only checks that firmware compiles (GitHub sets
  # CI=true).
  unless Enum.any?(env_files, fn filename ->
           Path.expand("../../../vehicles/#{vehicle_directory}/#{filename}", __DIR__)
           |> File.exists?()
         end) do
    if System.get_env("CI") == "true" do
      IO.warn(
        "no .env.exs for vehicle #{inspect(vehicle_directory)}: building with defaults (CI).",
        []
      )
    else
      raise "no .env.exs for vehicle #{inspect(vehicle_directory)}: a firmware built without it " <>
              "has generated secrets, no SSH keys (you would be locked out), a reset " <>
              "Wi-Fi list, and ZENOH_ENDPOINT_IP=127.0.0.1 (the vision unit reaches no " <>
              "router). Copy vehicles/#{vehicle_directory}/.env.exs.example to .env.exs and fill " <>
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

# RingLogger keeps the last 1024 entries: at debug, an open dashboard's requests fill them.
config :logger, backends: [RingLogger], level: :info

# `:nerves_hub_link` boots before the main app so a unit whose
# application crashes at startup stays reachable for an OTA fix.
config :shoehorn,
  init: [:nerves_runtime, :nerves_pack, :nerves_hub_link],
  handler: VisionFirmware.ShoehornHandler

# Both systems mount the application partition at `/root` and link `/data`, where
# NervesSSH, nerves_time and the rest of the codebase expect it, to it.
config :nerves, :erlinit,
  update_clock: true,
  hostname_pattern: vehicle_host

# The VENTUNO Q has the memory for 512 MiB Vulkan slabs, which keep a stereo
# segment's transient buffers pooled instead of allocated on every pair. IREE
# reads the size with getenv, which System.put_env does not reach: erlinit
# sets it before the VM starts.
if config_target() == :arduino_ventuno_q,
  do: config(:nerves, :erlinit, env: "IREE_HAL_VULKAN_SLAB_SIZE=#{512 * 1024 * 1024}")

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

# Nothing is published to ROS before NTP has set the clock (`Ros2Zenoh.Client`).
config :ros2_zenoh, clock_synchronized?: {NervesTime, :synchronized?, []}

# Saved vision parameters, on the application partition so they survive firmware updates.
config :vision_core, ecto_repos: [VisionCore.Repo]
config :vision_core, VisionCore.Repo, database: "/data/vision_core.db", pool_size: 1

# `NTP_SERVERS`, comma-separated, from the vehicle's `.env.exs`: a vehicle with
# a compute node lists it first (`ntp` in compose/compute).
config :nerves_time,
  servers:
    (case System.get_env("NTP_SERVERS", "") |> String.split(",", trim: true) do
       [] -> ["0.pool.ntp.org", "1.pool.ntp.org", "2.pool.ntp.org", "3.pool.ntp.org"]
       servers -> Enum.map(servers, &String.trim/1)
     end)

# `WIFI_NETWORKS` is an Elixir list literal of `{ssid, psk}` tuples from
# the vehicle's `.env.exs`. Deps are not compiled when Mix evaluates this
# file, so it is parsed with `Code.eval_string/1`.
wifi_networks =
  case System.get_env("WIFI_NETWORKS") do
    blank when blank in [nil, ""] ->
      []

    networks_literal ->
      {parsed, _} = Code.eval_string(networks_literal)

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

# HTTPS, which the dashboard's video decoder needs, with a self-signed certificate
# the unit generates at its first start (`VisionApi.SelfSignedCertificate`).
config :vision_api, VisionApiWeb.Endpoint,
  url: [host: vehicle_host],
  https: [
    port: 443,
    certfile: "/data/vision_api/certificate.pem",
    keyfile: "/data/vision_api/key.pem"
  ],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  # The unit is reached by name or by address: the socket takes the pages it served itself, under either.
  check_origin: :conn,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: VisionApiWeb.ErrorJSON], layout: false],
  pubsub_server: VisionApi.PubSub,
  server: true,
  code_reloader: false

# Addresses that name port 4100 reach the dashboard over HTTPS.
config :vision_api, https_redirect_ports: [80, 4100]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
