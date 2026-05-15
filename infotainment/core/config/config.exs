# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :infotainment_core,
  namespace: InfotainmentCore,
  ecto_repos: [InfotainmentCore.Repo],
  generators: [timestamp_type: :utc_datetime]

config :infotainment_core, InfotainmentCore.Repo,
  database: Path.expand("../infotainment_core_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Vehicle selection (composer module + Cantastic path + CAN mappings) lives
# in config/runtime.exs because it needs the vehicle package's modules to be
# compiled and loadable.

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()
