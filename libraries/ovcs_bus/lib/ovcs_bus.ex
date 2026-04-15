defmodule OvcsBus do
  @moduledoc """
  Node-local pub/sub bus shared across VMS, infotainment, and bridge
  libraries. Thin wrapper around `Phoenix.PubSub` registered under
  the module name `OvcsBus`.

  Every OVCS firmware image that depends on `ovcs_bus` gets its own
  local bus (one `Phoenix.PubSub` instance per node). Cross-firmware
  traffic — e.g. a bridge publishing to the VMS bus over the vehicle
  LAN — is an opt-in relay (`OvcsBus.Bridge.Mqtt`) that mirrors
  selected message names between the local bus and an MQTT broker.

  Usage mirrors the old `VmsCore.Bus`:

      OvcsBus.subscribe("messages")
      OvcsBus.broadcast("messages", %OvcsBus.Message{
        name: :ready_to_drive, value: true, source: __MODULE__
      })
  """

  @doc "Subscribe the calling process to `topic`."
  def subscribe(topic), do: Phoenix.PubSub.subscribe(__MODULE__, topic)

  @doc "Unsubscribe from `topic`. Processes exiting drop their subscriptions automatically."
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(__MODULE__, topic)

  @doc "Deliver `message` to every local subscriber of `topic`."
  def broadcast(topic, message), do: Phoenix.PubSub.local_broadcast(__MODULE__, topic, message)
end
