defmodule VisionCore.Exporter.ValueQueue do
  @moduledoc """
  The values of one output an exporter has yet to take, in their order,
  at most `limit` of them: a value that comes while it holds `limit`
  drops the oldest, which it counts (`dropped/1`).
  `VisionCore.Exporter.Runner` holds one for each output of an exporter
  whose delivery is `{:queue, limit}` (`c:VisionCore.Exporter.delivery/1`).
  """

  @enforce_keys [:limit]
  defstruct [:limit, values: :queue.new(), size: 0, dropped: 0]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          values: :queue.queue(term()),
          size: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @doc "An empty queue holding at most `limit` values."
  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0,
    do: %__MODULE__{limit: limit, values: :queue.new()}

  @doc "`queue` with `value` at its end, its oldest value dropped and counted when it was full."
  @spec push(t(), term()) :: t()
  def push(%__MODULE__{size: size, limit: limit} = queue, value) when size >= limit do
    {_oldest, values} = :queue.out(queue.values)
    %{queue | values: :queue.in(value, values), dropped: queue.dropped + 1}
  end

  def push(%__MODULE__{} = queue, value),
    do: %{queue | values: :queue.in(value, queue.values), size: queue.size + 1}

  @doc "The value at the head of `queue` and the queue without it, or `:empty`."
  @spec pop(t()) :: {:ok, term(), t()} | :empty
  def pop(%__MODULE__{} = queue) do
    case :queue.out(queue.values) do
      {{:value, value}, values} -> {:ok, value, %{queue | values: values, size: queue.size - 1}}
      {:empty, _values} -> :empty
    end
  end

  @doc "How many values `queue` dropped."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped
end
