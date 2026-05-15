import Config

# NOTE: `infotainment_api` is never a top-level Mix project in the OVCS
# run/build flow — it's always loaded as a dep of `infotainment_firmware`,
# whose own `config/runtime.exs` configures the vehicle composer +
# Cantastic before any app starts. This file only runs if
# `infotainment_api` is built directly and just ships the prod-release
# secrets block expected by Phoenix deployments.

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
