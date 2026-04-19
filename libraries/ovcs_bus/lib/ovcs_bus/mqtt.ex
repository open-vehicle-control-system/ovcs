defmodule OvcsBus.Mqtt do
  @moduledoc """
  MQTT-specific plumbing for `OvcsBus`.

  - `OvcsBus.Mqtt.Relay` — mirrors selected `OvcsBus.Message` names
    between the local bus and an MQTT broker (Tortoise311 client).
    One instance per firmware.
  - `OvcsBus.Mqtt.Broker` — supervised Mosquitto broker. One
    firmware per vehicle hosts it (conventionally the VMS); other
    firmwares are pure clients.

  Inbound messages arrive tagged with `:relay_origin = :mqtt` so
  the outbound path can skip messages it just injected, avoiding
  echo loops.

  `relay_child_from/1` and `broker_child_from/1` are the shared
  helpers each core's `Application` uses to opt a vehicle into
  the relay/broker via its composer's optional callbacks.
  """

  @doc """
  Child spec list for the composer's optional `bus_relay/0` callback:
  `[]` when the callback isn't exported or returns `nil`,
  `[{OvcsBus.Mqtt.Relay, opts}]` otherwise.
  """
  @spec relay_child_from(module()) :: [:supervisor.child_spec() | {module(), term()}]
  def relay_child_from(composer) when is_atom(composer) do
    composer |> optional_call(:bus_relay) |> wrap(OvcsBus.Mqtt.Relay)
  end

  @doc """
  Child spec list for the composer's optional `bus_broker/0` callback:
  `[]` when the callback isn't exported or returns `nil`,
  `[{OvcsBus.Mqtt.Broker, opts}]` otherwise.
  """
  @spec broker_child_from(module()) :: [:supervisor.child_spec() | {module(), term()}]
  def broker_child_from(composer) when is_atom(composer) do
    composer |> optional_call(:bus_broker) |> wrap(OvcsBus.Mqtt.Broker)
  end

  defp optional_call(mod, fun) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  end

  defp wrap(nil, _child), do: []
  defp wrap(opts, child), do: [{child, opts}]
end
