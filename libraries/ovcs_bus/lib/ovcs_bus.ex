defmodule OvcsBus do
  @moduledoc """
  Pub/sub bus of each VMS, infotainment and bridge firmware. Thin
  wrapper around `Phoenix.PubSub` registered under the module name
  `OvcsBus`.

  Every OVCS firmware image that depends on `ovcs_bus` gets its own
  `Phoenix.PubSub` instance, and `OvcsBus.Cluster` connects them into
  one distributed Erlang cluster. `broadcast/2` stays on the local
  node unless `config :ovcs_bus, cluster_broadcast: true`: a cluster
  broadcast suspends the publisher while the link to any peer is
  saturated, which stalls the component that published.

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
  Deliver `message` to every subscriber of `topic` on the local node,
  or on every node in the cluster when `:cluster_broadcast` is set.
  """
  def broadcast(topic, message) do
    check_source!(message)

    if Application.get_env(:ovcs_bus, :cluster_broadcast, false),
      do: Phoenix.PubSub.broadcast(__MODULE__, topic, message),
      else: Phoenix.PubSub.local_broadcast(__MODULE__, topic, message)
  end

  @doc "Deliver `message` only to subscribers on the local node, whatever `:cluster_broadcast` says."
  def local_broadcast(topic, message) do
    check_source!(message)
    Phoenix.PubSub.local_broadcast(__MODULE__, topic, message)
  end

  defp check_source!(%OvcsBus.Message{source: nil} = message) do
    raise ArgumentError,
          "OvcsBus.Message #{inspect(message.name)} has no :source. Subscribers gate on " <>
            "the source, so an unattributed message would match a component whose " <>
            "configured source is nil -- exactly the level that must command nothing."
  end

  defp check_source!(_message), do: :ok
end
