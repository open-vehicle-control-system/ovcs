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

vehicle = (System.get_env("VEHICLE") || "OVCS1")

config :vms_core, :vehicle, vehicle

default_can_mapping = case vehicle do
  "OVCS1" -> "ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4"
  "OVCSMini" -> "ovcs:vcan0"
  "OBD2" -> "obd2:can0,ovcs:can1"
end

config :cantastic,
  can_network_mappings: fn() ->
    (System.get_env("CAN_NETWORK_MAPPINGS") || default_can_mapping)
    |> String.split(",", trim: true)
    |> Enum.map(fn(i) ->
      [network_name, can_interface] = i |> String.split(":", trim: true)
      {network_name, can_interface}
    end)
  end,
  setup_can_interfaces: (System.get_env("SETUP_CAN_INTERFACES") == "true" || false),
  otp_app: :vms_core,
  priv_can_config_path: "can/vehicles/#{Macro.underscore(vehicle)}.yml"

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()

config :vms_core, :load_debugger_dependencies, true
config :vms_core, :socketcand_only, false
