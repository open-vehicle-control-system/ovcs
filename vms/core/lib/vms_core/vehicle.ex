defmodule VmsCore.Vehicle do
  @moduledoc """
  Contract for the VMS side of a vehicle package.

  A vehicle package exposes a module implementing this behaviour; it is the
  single entry point `vms_core` uses to wire a vehicle-specific supervision
  tree, dashboard, and generic controller configuration.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]
  @callback dashboard_configuration() :: map()
  @callback generic_controllers() :: map()
  @callback can_config_otp_app() :: atom()
  @callback can_config_path() :: String.t()
  @callback default_can_mapping(:host | :target) :: String.t()

  @doc """
  Optional — opts passed to `OvcsBus.Mqtt.Relay` so this vehicle's
  VMS relays selected bus messages to a shared MQTT broker. Return
  `nil` (or omit the callback) to skip the relay.
  """
  @callback bus_relay() :: map() | nil

  @doc """
  Optional — opts passed to `OvcsBus.Mqtt.Broker` (a supervised
  Mosquitto instance). When implemented, the VMS hosts the MQTT
  broker that the relay clients connect to. Return `nil` (or omit
  the callback) to rely on an external broker.
  """
  @callback bus_broker() :: map() | nil

  @optional_callbacks [
    dashboard_configuration: 0,
    generic_controllers: 0,
    bus_relay: 0,
    bus_broker: 0
  ]
end
