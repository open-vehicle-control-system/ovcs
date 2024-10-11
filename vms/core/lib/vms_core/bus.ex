defmodule VmsCore.Bus do
  @moduledoc """
    VMS internal bus allowing to decouple the different modules and reuse them in multiple vehicles
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(VmsCore.Bus, topic)
  end

  def broadcast(topic, message) do
    Phoenix.PubSub.local_broadcast(VmsCore.Bus, topic, message)
  end
end
