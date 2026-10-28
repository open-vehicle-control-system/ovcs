defmodule OvcsBusGateway.Envelope do
  @moduledoc """
  The JSON shape every bus signal leaves the gateway in.

  - `:node` — role of the node the signal was published on (`"vms"`).
  - `:source` — publishing module, as `inspect/1` prints it (`"VmsCore.Vehicle"`).
  - `:name` — signal name as a string; a name that is neither an atom nor a UTF-8 string is
    its `inspect/1` text.
  - `:value` — JSON-safe value, see `encode_value/1`.
  - `:unit` — unit of a physical value as a string, made JSON-safe like `:name`, or `nil`.
  - `:changed_at` — milliseconds since the Unix epoch, stamped by the forwarder on the
    publishing node when it receives the message that last changed the value.
  - `:published_at` — milliseconds since the Unix epoch, stamped the same way on the last
    message published, changed or not, or `nil` when the forwarder does not report it. The
    forwarder refreshes a steadily published signal every refresh interval.
  - `:stale` — set by `OvcsBusGateway.Collector`: `true` when the signal has not been received
    for its stale delay, `false` once it is received again, `nil` when unknown: presence
    signals and signals from a forwarder that does not refresh.
  """

  @derive Jason.Encoder
  @enforce_keys [:node, :source, :name, :changed_at, :published_at]
  defstruct [:node, :source, :name, :value, :unit, :changed_at, :published_at, :stale]

  @type t :: %__MODULE__{
          node: String.t(),
          source: String.t(),
          name: String.t(),
          value: term(),
          unit: String.t() | nil,
          changed_at: integer(),
          published_at: integer() | nil,
          stale: boolean() | nil
        }

  @doc """
  Builds the envelope of `message`, published on the node playing `role`, whose value last
  changed at `changed_at` and which was last published at `published_at`. Its `:stale` is
  `nil`.
  """
  @spec new(String.t(), OvcsBus.Message.t(), integer(), integer() | nil) :: t()
  def new(role, %OvcsBus.Message{} = message, changed_at, published_at) do
    %__MODULE__{
      node: role,
      source: inspect(message.source),
      name: encode_text(message.name),
      value: encode_value(message.value),
      unit: if(message.unit, do: encode_text(message.unit)),
      changed_at: changed_at,
      published_at: published_at
    }
  end

  @doc """
  The `{node, source, name}` identifying a signal.
  """
  @spec key(t()) :: {String.t(), String.t(), String.t()}
  def key(%__MODULE__{node: node, source: source, name: name}), do: {node, source, name}

  @doc """
  Converts a bus value into one `Jason` can encode.

  Numbers, booleans, `nil` and valid UTF-8 binaries are kept. A finite `Decimal` becomes an
  exact JSON number, any other atom its name, and any other term (including binaries that
  are not UTF-8 and non-finite decimals) its `inspect/1` text.
  """
  @spec encode_value(term()) :: term()
  def encode_value(value)
      when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
      do: value

  def encode_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  def encode_value(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: inspect(value),
      else: Jason.Fragment.new(Decimal.to_string(value, :normal))
  end

  def encode_value(value) when is_atom(value), do: Atom.to_string(value)
  def encode_value(value), do: inspect(value)

  defp encode_text(text) when is_atom(text), do: Atom.to_string(text)

  defp encode_text(text) when is_binary(text) do
    if String.valid?(text), do: text, else: inspect(text)
  end

  defp encode_text(text), do: inspect(text)
end
