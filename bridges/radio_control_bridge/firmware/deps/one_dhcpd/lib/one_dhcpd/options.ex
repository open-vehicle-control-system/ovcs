defmodule OneDHCPD.Options do
  @moduledoc false
  alias OneDHCPD.Option

  @dho_pad 0
  @dho_end 255

  @doc """
  Decode DHCP options
  """
  @spec decode(binary()) :: Keyword.t()
  def decode(opts), do: decode(opts, [])

  defp decode(<<@dho_pad, rest::binary>>, acc), do: decode(rest, acc)
  defp decode(<<@dho_end, _::binary>>, acc), do: Enum.reverse(acc)

  defp decode(<<code, len, value::binary-size(len), rest::binary>>, acc) do
    decode(rest, [Option.decode(code, value) | acc])
  end

  @doc """
  Encode the specified list of options to a binary for a DHCP packet.
  """
  @spec encode(Keyword.t()) :: binary()
  def encode(options) do
    encoded_options = Enum.map(options, fn {key, value} -> Option.encode(key, value) end)
    IO.iodata_to_binary([encoded_options, @dho_end])
  end
end
