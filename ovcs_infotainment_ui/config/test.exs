import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ovcs_infotainment_ui, OvcsInfotainmentUiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TxwhdUHwau+YIIrce9Ct2kJO/wjMYxFckzkp0omgYMJVYw4LXLi5BBtjcex9yH6A",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
