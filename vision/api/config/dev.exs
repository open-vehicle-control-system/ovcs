import Config

# 4000 is the VMS API's.
config :vision_api, VisionApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4100],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "nHk3V0pZ4mWJm7wqQq0bX9rFvS2yD5uT8eL1cA6gR3oI7hN4jK0sP2xY9zB5vE1u"

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
