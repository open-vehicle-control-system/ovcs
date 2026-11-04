defmodule VisionCore.TestPng do
  @moduledoc """
  A PNG reader for the tests, independent of `VisionCore.Debug.Png`: it
  checks the signature, the chunk order, each chunk's CRC and the filter
  bytes, and answers the image's header fields and its unfiltered pixels
  as the file holds them (16-bit samples big-endian).
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @channels %{0 => 1, 2 => 3}

  @type t :: %{
          width: pos_integer(),
          height: pos_integer(),
          bit_depth: pos_integer(),
          colour_type: 0 | 2,
          pixels: binary()
        }

  @doc "Reads `png`, raising when it is not a well-formed grey or RGB image."
  @spec decode!(binary()) :: t()
  def decode!(<<@signature, rest::binary>>) do
    [{"IHDR", header} | chunks] = chunks(rest)
    <<width::32, height::32, bit_depth, colour_type, 0, 0, 0>> = header
    {"IEND", <<>>} = List.last(chunks)

    compressed = for {"IDAT", data} <- chunks, into: <<>>, do: data
    row_bytes = width * Map.fetch!(@channels, colour_type) * div(bit_depth, 8)

    pixels =
      for <<0, row::binary-size(^row_bytes) <- :zlib.uncompress(compressed)>>, into: <<>>, do: row

    true = byte_size(pixels) == row_bytes * height

    %{
      width: width,
      height: height,
      bit_depth: bit_depth,
      colour_type: colour_type,
      pixels: pixels
    }
  end

  defp chunks(<<>>), do: []

  defp chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>
       ) do
    ^crc = :erlang.crc32(type <> data)
    [{type, data} | chunks(rest)]
  end
end
