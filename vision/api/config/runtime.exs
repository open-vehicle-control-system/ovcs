import Config

# Runs only when vision_api is the top-level project; the vision firmware
# configures the endpoint itself.
if System.get_env("PHX_SERVER") do
  config :vision_api, VisionApiWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing; generate one with mix phx.gen.secret"

  config :vision_api, VisionApiWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4100")
    ],
    secret_key_base: secret_key_base
end
