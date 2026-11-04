defmodule VisionCore.Debug.Png do
  @moduledoc """
  A PNG writer and reader for the debug export's images, on Erlang's
  `:zlib` and `:erlang.crc32/1`: 8-bit grey, 16-bit grey and 8-bit RGB.
  Each row is written unfiltered and the image is one `IDAT` chunk, so a
  file is larger than an optimising encoder's and cheap to make.

  The writing functions take the pixels row-major, and raise
  `ArgumentError` when their size does not fill `width` × `height`.
  `decode/1` reads what they write, and nothing else.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @grey 0
  @rgb 2

  @type image :: %{
          width: pos_integer(),
          height: pos_integer(),
          bit_depth: 8 | 16,
          colour: :grey | :rgb,
          pixels: binary()
        }

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

  @doc """
  Reads a PNG the functions above could have written: 8-bit grey, 16-bit
  grey or 8-bit RGB, not interlaced, every row unfiltered, in one or more
  `IDAT` chunks between `IHDR` and `IEND`.

  Answers `{:ok, image}`, where `pixels` is row-major as the writing
  functions take them (16-bit samples little-endian), or `{:error, reason}`
  for anything else: `:not_a_png`, `:truncated`, `:trailing_data`,
  `:bad_header`, `:bad_data`, `:bad_pixels`, `{:bad_crc, chunk_type}`,
  `{:unexpected_chunk, chunk_type}`, `{:unsupported_format, header_fields}`
  or `{:unsupported_filter, filter_type}`.
  """
  @spec decode(binary()) :: {:ok, image()} | {:error, term()}
  def decode(<<@signature, chunks::binary>>) do
    with {:ok, chunks} <- read_chunks(chunks, []),
         {:ok, header, compressed} <- split_chunks(chunks),
         {:ok, image} <- parse_header(header),
         {:ok, scanlines} <- inflate(compressed),
         {:ok, pixels} <- unfilter(scanlines, image) do
      {:ok, Map.put(image, :pixels, to_little_endian(pixels, image))}
    end
  end

  def decode(_binary), do: {:error, :not_a_png}

  defp read_chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         chunks
       ) do
    cond do
      :erlang.crc32([type, data]) != crc -> {:error, {:bad_crc, type}}
      type != "IEND" -> read_chunks(rest, [{type, data} | chunks])
      rest != <<>> -> {:error, :trailing_data}
      true -> {:ok, Enum.reverse([{type, data} | chunks])}
    end
  end

  defp read_chunks(_truncated, _chunks), do: {:error, :truncated}

  defp split_chunks([{"IHDR", header} | chunks]) do
    case Enum.split_while(chunks, &match?({"IDAT", _data}, &1)) do
      {image_data, [{"IEND", _data}]} ->
        {:ok, header, IO.iodata_to_binary(for {_type, data} <- image_data, do: data)}

      {_image_data, [{type, _data} | _rest]} ->
        {:error, {:unexpected_chunk, type}}
    end
  end

  defp split_chunks([{type, _data} | _rest]), do: {:error, {:unexpected_chunk, type}}

  defp parse_header(<<width::32, height::32, bit_depth, colour_type, 0, 0, interlace>>)
       when width > 0 and height > 0 do
    case {colour_type, bit_depth, interlace} do
      {@grey, bit_depth, 0} when bit_depth in [8, 16] ->
        {:ok, %{width: width, height: height, bit_depth: bit_depth, colour: :grey}}

      {@rgb, 8, 0} ->
        {:ok, %{width: width, height: height, bit_depth: 8, colour: :rgb}}

      _unsupported ->
        {:error,
         {:unsupported_format,
          %{bit_depth: bit_depth, colour_type: colour_type, interlace: interlace}}}
    end
  end

  defp parse_header(_header), do: {:error, :bad_header}

  defp inflate(compressed) do
    {:ok, :zlib.uncompress(compressed)}
  rescue
    ErlangError -> {:error, :bad_data}
  end

  defp unfilter(scanlines, %{width: width, height: height} = image) do
    row_bytes = width * bytes_per_pixel(image)

    if byte_size(scanlines) == (row_bytes + 1) * height,
      do: strip_filter_bytes(row_bytes, scanlines, []),
      else: {:error, :bad_pixels}
  end

  defp bytes_per_pixel(%{colour: :grey, bit_depth: bit_depth}), do: div(bit_depth, 8)
  defp bytes_per_pixel(%{colour: :rgb}), do: 3

  defp strip_filter_bytes(_row_bytes, <<>>, rows),
    do: {:ok, rows |> Enum.reverse() |> IO.iodata_to_binary()}

  defp strip_filter_bytes(row_bytes, scanlines, rows) do
    case scanlines do
      <<0, row::binary-size(^row_bytes), rest::binary>> ->
        strip_filter_bytes(row_bytes, rest, [row | rows])

      <<filter_type, _row::binary>> ->
        {:error, {:unsupported_filter, filter_type}}
    end
  end

  defp to_little_endian(pixels, %{bit_depth: 16}),
    do: for(<<sample::16-big <- pixels>>, into: <<>>, do: <<sample::16-little>>)

  defp to_little_endian(pixels, _format), do: pixels

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
