defmodule VisionCore.Debug.Png do
  @moduledoc """
  A PNG writer for the debug export's images, on Erlang's `:zlib` and
  `:erlang.crc32/1`: 8-bit grey, 16-bit grey and 8-bit RGB. Each row is
  written unfiltered and the image is one `IDAT` chunk, so a file is
  larger than an optimising encoder's and cheap to make.

  Every function takes the pixels row-major, and raises `ArgumentError`
  when their size does not fill `width` × `height`.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @grey 0
  @rgb 2

  @doc "An 8-bit grey image from `width * height` bytes."
  @spec grey(binary(), pos_integer(), pos_integer()) :: binary()
  def grey(pixels, width, height), do: encode(pixels, width, height, 1, 8, @grey)

  @doc """
  A 16-bit grey image from `width * height` little-endian unsigned 16-bit
  samples, which PNG stores big-endian.
  """
  @spec grey16(binary(), pos_integer(), pos_integer()) :: binary()
  def grey16(pixels, width, height) do
    big_endian = for <<sample::16-little <- pixels>>, into: <<>>, do: <<sample::16-big>>
    encode(big_endian, width, height, 2, 16, @grey)
  end

  @doc "An 8-bit RGB image from `width * height * 3` bytes, red first."
  @spec rgb(binary(), pos_integer(), pos_integer()) :: binary()
  def rgb(pixels, width, height), do: encode(pixels, width, height, 3, 8, @rgb)

  defp encode(pixels, width, height, bytes_per_pixel, bit_depth, colour_type)
       when width > 0 and height > 0 do
    row_bytes = width * bytes_per_pixel

    if byte_size(pixels) != row_bytes * height do
      raise ArgumentError,
            "a #{width}x#{height} image needs #{row_bytes * height} bytes, got #{byte_size(pixels)}"
    end

    rows = for <<row::binary-size(^row_bytes) <- pixels>>, into: <<>>, do: <<0, row::binary>>

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<width::32, height::32, bit_depth, colour_type, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(rows)),
      chunk("IEND", <<>>)
    ])
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
end
