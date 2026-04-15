defmodule InfotainmentCore.Vehicle do
  @moduledoc """
  Contract for the infotainment side of a vehicle package.

  A vehicle package exposes a module implementing this behaviour; it is the
  single entry point `infotainment_core` uses to wire a vehicle-specific
  supervision tree on the infotainment side.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]
  @callback infotainment_configuration() :: map()
  @callback can_config_otp_app() :: atom()
  @callback can_config_path() :: String.t()
  @callback default_can_mapping(:host | :target) :: String.t()

  @doc """
  Optional — opts passed to `OvcsBus.Mqtt.Relay` so this vehicle's
  infotainment side relays selected bus messages to a shared MQTT
  broker. Return `nil` (or omit the callback) to skip the relay.
  """
  @callback bus_relay() :: map() | nil

  @optional_callbacks [infotainment_configuration: 0, bus_relay: 0]
end
