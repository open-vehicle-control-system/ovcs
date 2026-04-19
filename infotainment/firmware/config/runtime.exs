import Config

vehicle =
  OvcsVehicle.Firmware.resolve_vehicle(
    __DIR__,
    config_env(),
    Application.compile_env(:infotainment_firmware, :vehicle)
  )

if vehicle && config_env() != :test do
  infotainment = vehicle.infotainment()

  config :infotainment_core, :vehicle, infotainment

  config :cantastic,
    can_network_mappings: fn ->
      (System.get_env("CAN_NETWORK_MAPPINGS") || infotainment.default_can_mapping(:host))
      |> String.split(",", trim: true)
      |> Enum.map(fn i ->
        [network_name, can_interface] = i |> String.split(":", trim: true)
        {network_name, can_interface}
      end)
    end,
    otp_app: vehicle.can_config_otp_app(),
    priv_can_config_path: infotainment.can_config_path()
end

if System.get_env("PHX_SERVER") do
  config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/infotainment_api/infotainment_api.db
      """

  config :infotainment_api, InfotainmentApi.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :infotainment_api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :infotainment_api, InfotainmentApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
