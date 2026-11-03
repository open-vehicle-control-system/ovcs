defmodule OvcsBusGateway.Subscribers do
  @moduledoc """
  Registry of the processes receiving the envelopes the collector publishes.

  A subscriber calls `subscribe/1` and receives `{:ovcs_bus_gateway, [Envelope.t()]}`
  messages. Its role, such as `:signals_channel`, lets `count/1` tell how many of a kind there
  are.
  """

  alias OvcsBusGateway.Envelope

  @topic :envelopes

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc """
  Registers the calling process as a subscriber playing `role`.
  """
  @spec subscribe(term()) :: :ok
  def subscribe(role \\ nil) do
    {:ok, _owner} = Registry.register(__MODULE__, @topic, role)
    :ok
  end

  @doc """
  How many subscribers play `role`.
  """
  @spec count(term()) :: non_neg_integer()
  def count(role), do: Registry.count_match(__MODULE__, @topic, role)

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
