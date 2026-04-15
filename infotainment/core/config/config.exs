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

vehicle_name = (System.get_env("VEHICLE") || "OVCS1")

{vehicle_module, cantastic_otp_app, cantastic_priv_path} = case vehicle_name do
  "OVCS1" -> {Ovcs1.Infotainment.Composer, :ovcs1, "can/infotainment.yml"}
  "OBD2"  -> {Obd2.Infotainment.Composer,  :obd2,  "can/infotainment.yml"}
end

config :infotainment_core, :vehicle, vehicle_module

config :cantastic,
  can_network_mappings: fn() ->
    (System.get_env("CAN_NETWORK_MAPPINGS") || "ovcs:vcan1")
    |> String.split(",", trim: true)
    |> Enum.map(fn(i) ->
      [network_name, can_interface] = i |> String.split(":", trim: true)
      {network_name, can_interface}
    end)
  end,
  setup_can_interfaces: (System.get_env("SETUP_CAN_INTERFACES") == "true" || false),
  otp_app: cantastic_otp_app,
  priv_can_config_path: cantastic_priv_path


# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()
