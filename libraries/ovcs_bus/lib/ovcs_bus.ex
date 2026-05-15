defmodule OvcsBus do
  @moduledoc """
  Cluster-wide pub/sub bus shared across VMS, infotainment, and bridge
  firmwares. Thin wrapper around `Phoenix.PubSub` registered under
  the module name `OvcsBus`.

  Every OVCS firmware image that depends on `ovcs_bus` gets its own
  `Phoenix.PubSub` instance. `OvcsBus.Cluster` connects them into a
  single distributed Erlang cluster at boot, so `broadcast/2`
  propagates to every subscriber on every node — no separate relay
  required.

  Usage:

      OvcsBus.subscribe("messages")
      OvcsBus.broadcast("messages", %OvcsBus.Message{
        name: :ready_to_drive, value: true, source: __MODULE__
      })
  """

  @doc "Subscribe the calling process to `topic`."
  def subscribe(topic), do: Phoenix.PubSub.subscribe(__MODULE__, topic)

  @doc "Unsubscribe from `topic`. Processes exiting drop their subscriptions automatically."
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(__MODULE__, topic)

  @doc """
  Deliver `message` to every subscriber of `topic` on every node in
  the cluster (including the local node). Use when message fan-out
  matters across the vehicle's BEAMs — typical for component state
  broadcasts, `:ready_to_drive` updates, metrics, etc.
  """
  def broadcast(topic, message), do: Phoenix.PubSub.broadcast(__MODULE__, topic, message)

  @doc """
  Deliver `message` only to subscribers on the local node. Prefer
  `broadcast/2` unless you have a specific reason to keep traffic
  off the cluster.
  """
  def local_broadcast(topic, message),
    do: Phoenix.PubSub.local_broadcast(__MODULE__, topic, message)
end
