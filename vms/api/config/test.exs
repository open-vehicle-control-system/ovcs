import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :vms_api, VmsApi.Repo,
  database: Path.expand("../api_test.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :vms_api, VmsApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dA8PXA7NOCOZuq/5N3fruI+0Y/jWhLGj3Tg5npXEmo8n+7Sclqs0hAvZXzQoex1J",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Stub cantastic so its Application can boot without a real CAN topology.
# `read_configuration/0` is skipped because no `priv_can_config_path` is set,
# and `can_network_mappings: fn -> [] end` short-circuits the mapping loop.
config :cantastic,
  can_network_mappings: fn -> [] end,
  otp_app: :vms_api
