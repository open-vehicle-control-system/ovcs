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
    with padded   <- string |> String.pad_leading(2, "0"),
         {int, _} <- padded |> Integer.parse()
    do
      int
    else
      :error -> {:error, "'#{string}' is not a valid integer"}
    end
  end

  def integer_to_bin_big(integer, size \\ 16)
  def integer_to_bin_big(nil, _size), do: nil
  def integer_to_bin_big(integer, size) do
    <<integer::big-integer-size(size)>>
  end

  def integer_to_bin_little(integer, size \\ 16) do
    <<integer::little-integer-size(size)>>
  end
end
