defmodule OneDHCPD.Utility do
  @moduledoc false

  @spec decode_integer(<<_::32>>) :: non_neg_integer()
  def decode_integer(<<a::32>>), do: a
  def encode_integer(type, a), do: <<type, 4, a::32>>

  @spec decode_short(<<_::16>>) :: 0..65535
  def decode_short(<<a::16>>), do: a
  def encode_short(type, a), do: <<type, 2, a::16>>

  @spec decode_byte(<<_::8>>) :: byte()
  def decode_byte(<<a::8>>), do: a
  def encode_byte(type, a), do: <<type, 1, a::8>>

  @spec decode_ip(<<_::32>>) :: :inet.ip_address()
  def decode_ip(<<a, b, c, d>>), do: {a, b, c, d}
  def encode_ip(type, {a, b, c, d}), do: <<type, 4, a, b, c, d>>
  def encode_ip_raw({a, b, c, d}), do: <<a, b, c, d>>

  @spec decode_hwaddr(<<_::48>>) :: [byte(), ...]
  def decode_hwaddr(<<a, b, c, d, e, f>>), do: [a, b, c, d, e, f]
  def encode_hwaddr(type, [a, b, c, d, e, f]), do: <<type, 6, a, b, c, d, e, f>>
  def encode_hwaddr_raw([a, b, c, d, e, f]), do: <<a, b, c, d, e, f>>

  @spec decode_iplist(binary()) :: [:inet.ip4_address()]
  def decode_iplist(<<a, b, c, d, t::binary>>), do: [{a, b, c, d} | decode_iplist(t)]
  def decode_iplist(<<>>), do: []

  @spec encode_iplist(byte(), [:inet.ip4_address()]) :: binary()
  def encode_iplist(type, list) do
    data = Enum.map(list, fn {a, b, c, d} -> <<a, b, c, d>> end) |> IO.iodata_to_binary()
    IO.iodata_to_binary([type, byte_size(data), data])
  end

  @spec decode_shortlist(binary()) :: [0..65535]
  def decode_shortlist(<<h::16, t::binary>>) do
    [h | decode_shortlist(t)]
  end

  def decode_shortlist(<<>>), do: []

  @spec encode_shortlist(byte(), [0..65535]) :: binary()
  def encode_shortlist(type, list) do
    data = Enum.map(list, fn a -> <<a::16>> end) |> IO.iodata_to_binary()
    IO.iodata_to_binary([type, byte_size(data), data])
  end

  @spec decode_vendor(binary()) :: binary()
  def decode_vendor(value), do: value
  @spec encode_vendor(byte(), binary()) :: binary()
  def encode_vendor(type, value), do: <<type, byte_size(value), value::binary>>

  @spec encode_string(byte(), binary()) :: binary()
  def encode_string(type, value), do: <<type, byte_size(value), value::binary>>
end
