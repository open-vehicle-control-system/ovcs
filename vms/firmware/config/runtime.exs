import Config

vehicle_name = Application.compile_env(:vms_firmware, :vehicle) || System.get_env("VEHICLE")

# Split-mode host runs us from `vms/firmware/` without pulling the
# vehicle as a Mix dep — add its compiled ebin before we dereference
# the module. Nerves target builds ship the vehicle inside the release,
# but `Code.prepend_path` on a directory that's already on the path is
# a cheap no-op.
if vehicle_name do
  dir = Macro.underscore(vehicle_name)
  ebin = Path.expand("../../../vehicles/#{dir}/_build/#{config_env()}/lib/#{dir}/ebin", __DIR__)
  Code.prepend_path(ebin)
end

if vehicle_name && config_env() != :test do
  vehicle = Module.concat([vehicle_name])
  vms = vehicle.vms()

  config :vms_core, :vehicle, vms

  config :cantastic,
    can_network_mappings: {
      VmsFirmware.Util.NetworkMapper,
      :can_network_mappings,
      [System.get_env("CAN_NETWORK_MAPPINGS") || vms.default_can_mapping(:host)]
    },
    otp_app: vehicle.can_config_otp_app(),
    priv_can_config_path: vms.can_config_path()
end

# Phoenix endpoint opt-in for release builds (matches the original
# `vms/api` runtime.exs guidance).
if System.get_env("PHX_SERVER") do
  config :vms_api, VmsApiWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/api/api.db
      """

  config :vms_api, VmsApi.Repo,
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

  config :vms_api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :vms_api, VmsApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
