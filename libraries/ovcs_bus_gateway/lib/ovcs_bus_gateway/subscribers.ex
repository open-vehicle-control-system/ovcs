defmodule OvcsBusGateway.Subscribers do
  @moduledoc """
  Registry of the processes receiving the envelopes the collector publishes.

  A subscriber calls `subscribe/0` and receives `{:ovcs_bus_gateway, [Envelope.t()]}`
  messages.
  """

  alias OvcsBusGateway.Envelope

  @topic :envelopes

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc """
  Registers the calling process as a subscriber.
  """
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _owner} = Registry.register(__MODULE__, @topic, nil)
    :ok
  end

  @doc """
  Sends `envelopes` to every subscriber.
  """
  @spec dispatch([Envelope.t()]) :: :ok
  def dispatch(envelopes) do
    Registry.dispatch(__MODULE__, @topic, fn subscribers ->
      for {pid, _value} <- subscribers, do: send(pid, {:ovcs_bus_gateway, envelopes})
    end)
  end
end
