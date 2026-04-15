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
  """
end
