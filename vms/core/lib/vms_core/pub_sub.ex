defmodule VmsCore.PubSub do
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(VmsCore.Bus, topic)
  end

  def broadcast(topic, message) do
    Phoenix.PubSub.local_broadcast(VmsCore.Bus, topic, message)
  end
end
