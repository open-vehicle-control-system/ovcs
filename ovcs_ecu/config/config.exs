# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ovcs_ecu, :can_networks, System.get_env("CAN_NETWORKS") || "drive:vcan0,confort:vcan1"
config :ovcs_ecu, :manual_setup, System.get_env("MANUAL_SETUP") == "true" || false
config :ovcs_ecu, :vehicle, System.get_env("VEHICLE") || "polo-2007-bluemotion-leaf-em57"

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]