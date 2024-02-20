# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

import_config "../../core/config/config.exs"

config :infotainment_api,
  ecto_repos: [InfotainmentApi.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :infotainment_api, InfotainmentApiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: InfotainmentApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: InfotainmentApi.PubSub,
  live_view: [signing_salt: "NYYbIS2A"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
