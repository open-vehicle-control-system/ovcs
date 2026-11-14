import Config

config :vision_api, VisionApiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # The socket takes the pages the endpoint itself served: those of the host, scheme and port of the request.
  check_origin: :conn,
  render_errors: [formats: [json: VisionApiWeb.ErrorJSON], layout: false],
  pubsub_server: VisionApi.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :mime, :types, %{"application/vnd.api+json" => ["jsonapi"]}
config :phoenix_template, :format_encoders, jsonapi: Jason

import_config "#{config_env()}.exs"
