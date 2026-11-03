defmodule OvcsBusGateway.Nodes do
  @moduledoc """
  The nodes of the bus as the gateway sees them, built from its envelopes: each node's presence,
  from the collector's `connected` signal (`OvcsBusGateway.Collector.presence?/1`), and its other
  signals.
  """

  alias OvcsBusGateway.{Collector, Envelope}

  @enforce_keys [:id, :connected, :signals]
  defstruct [:id, :connected, :signals]

  @typedoc "`connected` is `nil` until the gateway has seen the node's presence."
  @type t :: %__MODULE__{id: String.t(), connected: boolean() | nil, signals: [Envelope.t()]}

  @doc "The nodes of `envelopes`, by id, their signals in the order of `envelopes`."
  @spec list([Envelope.t()]) :: [t()]
  def list(envelopes) do
    envelopes
    |> Enum.group_by(& &1.node)
    |> Enum.map(fn {id, node_envelopes} -> node(id, node_envelopes) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "How many of `node`'s signals the gateway marked stale."
  @spec stale_count(t()) :: non_neg_integer()
  def stale_count(%__MODULE__{signals: signals}), do: Enum.count(signals, &(&1.stale == true))

  @doc "When one of `node`'s values last changed, `nil` for a node without signals."
  @spec last_change_at(t()) :: integer() | nil
  def last_change_at(%__MODULE__{signals: signals}),
    do: signals |> Enum.map(& &1.changed_at) |> Enum.max(fn -> nil end)

  defp node(id, envelopes) do
    {presence, signals} = Enum.split_with(envelopes, &Collector.presence?/1)
    %__MODULE__{id: id, connected: connected(presence), signals: signals}
  end

  defp connected([%Envelope{value: value}]) when is_boolean(value), do: value
  defp connected(_presence), do: nil
end
