# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :vms_core,
  namespace: VmsCore,
  ecto_repos: [VmsCore.Repo],
  generators: [timestamp_type: :utc_datetime]

config :vms_core, VmsCore.Repo,
  database: Path.expand("../vms_core_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

vehicle = System.get_env("VEHICLE") || "polo-2007-bluemotion-leaf-em57"

config :vms_core, :vehicle, vehicle

config :cantastic,
  can_networks: (System.get_env("CAN_NETWORKS") || "ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,polo_comfort:vcan3"),
  setup_can_interfaces: (System.get_env("SETUP_CAN_INTERFACES") == "true" || false),
  otp_app: :vms_core,
  priv_can_config_path: "vehicles/#{vehicle}.yml"

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()

config :vms_core, :load_debugger_dependencies, true
