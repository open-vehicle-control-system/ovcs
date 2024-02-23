defmodule Cantastic.Util do
  def hex_to_bin(nil), do: nil
  def hex_to_bin(hex_data) do
    hex_data
    |> String.pad_leading(2, "0")
    |> Base.decode16!()
  end

  def bin_to_hex(raw_data) do
    raw_data |> Base.encode16()
  end

  def integer_to_hex(integer) do
    integer
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
  end

  def string_to_integer(string) do
    {int, _} = Integer.parse(string)
    int
  end

  def integer_to_bin_big(integer, size \\ 16) do
    <<integer::big-integer-size(size)>>
  end

  def integer_to_bin_little(integer, size \\ 16) do
    <<integer::little-integer-size(size)>>
  end

  def unsigned_integer_to_bin_big(nil), do: nil
  def unsigned_integer_to_bin_big(integer) do
    :binary.encode_unsigned(integer)
  end
end
