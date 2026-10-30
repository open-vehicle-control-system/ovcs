import Config

config :vision_api, VisionApiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: VisionApiWeb.ErrorJSON], layout: false],
  pubsub_server: VisionApi.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :mime, :types, %{"application/vnd.api+json" => ["jsonapi"]}

import_config "#{config_env()}.exs"
