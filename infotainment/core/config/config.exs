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

vehicle = System.get_env("VEHICLE") || "polo-2007-bluemotion-leaf-em57"

config :infotainment_core, :vehicle, vehicle

config :cantastic,
  can_networks: (System.get_env("CAN_NETWORKS") || "ovcs:vcan0,polo_drive:vcan2"),
  setup_can_interfaces: (System.get_env("SETUP_CAN_INTERFACES") == "true" || false),
  otp_app: :infotainment_core,
  priv_can_config_path: "vehicles/#{vehicle}.yml"


# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()
