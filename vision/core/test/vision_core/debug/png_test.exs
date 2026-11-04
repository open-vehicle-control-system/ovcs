defmodule VisionCore.Debug.PngTest do
  use ExUnit.Case, async: true

  alias VisionCore.Debug.Png
  alias VisionCore.TestPng

  test "writes a grey, a 16-bit and an RGB image a decoder reads back" do
    grey = :binary.list_to_bin(Enum.map(0..11, &(&1 * 20)))

    assert %{width: 4, height: 3, bit_depth: 8, colour_type: 0} =
             image = TestPng.decode!(Png.grey(grey, 4, 3))

    assert image.pixels == grey

    millimetres = [0, 1, 255, 256, 1_000, 65_535]
    little_endian = for mm <- millimetres, into: <<>>, do: <<mm::16-little>>
    deep = TestPng.decode!(Png.grey16(little_endian, 3, 2))
    assert %{width: 3, height: 2, bit_depth: 16, colour_type: 0} = deep
    assert for(<<mm::16-big <- deep.pixels>>, do: mm) == millimetres

    rgb = :binary.list_to_bin(Enum.to_list(1..18))

    assert %{width: 3, height: 2, bit_depth: 8, colour_type: 2} =
             image = TestPng.decode!(Png.rgb(rgb, 3, 2))

    assert image.pixels == rgb
  end

  test "refuses pixels that do not fill the image" do
    assert_raise ArgumentError, ~r/needs 12 bytes/, fn -> Png.grey(<<0, 1, 2>>, 4, 3) end
    assert_raise ArgumentError, ~r/needs 12 bytes/, fn -> Png.grey16(<<0, 1, 2>>, 3, 2) end
  end

  describe "decode/1" do
    test "reads back what each writer function wrote" do
      grey = :binary.list_to_bin(Enum.map(0..11, &(&1 * 20)))

      assert Png.decode(Png.grey(grey, 4, 3)) ==
               {:ok, %{width: 4, height: 3, bit_depth: 8, colour: :grey, pixels: grey}}

      millimetres = for mm <- [0, 1, 255, 256, 1_000, 65_535], into: <<>>, do: <<mm::16-little>>

      assert Png.decode(Png.grey16(millimetres, 3, 2)) ==
               {:ok, %{width: 3, height: 2, bit_depth: 16, colour: :grey, pixels: millimetres}}

      rgb = :binary.list_to_bin(Enum.to_list(1..18))

      assert Png.decode(Png.rgb(rgb, 3, 2)) ==
               {:ok, %{width: 3, height: 2, bit_depth: 8, colour: :rgb, pixels: rgb}}
    end

    test "joins the data of several IDAT chunks" do
      compressed = :zlib.compress(<<0, 1, 2, 0, 3, 4>>)
      half = div(byte_size(compressed), 2)
      <<first::binary-size(^half), second::binary>> = compressed

      png =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<2::32, 2::32, 8, 0, 0, 0, 0>>),
          chunk("IDAT", first),
          chunk("IDAT", second),
          chunk("IEND", <<>>)
        ])

      assert {:ok, %{width: 2, height: 2, pixels: <<1, 2, 3, 4>>}} = Png.decode(png)
    end

    test "refuses what is not a PNG" do
      assert {:error, :not_a_png} = Png.decode("GIF89a, not a PNG")
      assert {:error, :not_a_png} = Png.decode(<<>>)
    end

    test "refuses a truncated file and a corrupted chunk" do
      png = Png.grey(<<1, 2, 3, 4>>, 2, 2)

      assert {:error, :truncated} = Png.decode(binary_part(png, 0, byte_size(png) - 5))
      assert {:error, :truncated} = Png.decode(binary_part(png, 0, byte_size(png) - 12))

      <<before::binary-size(16), byte, rest::binary>> = png
      assert {:error, {:bad_crc, "IHDR"}} = Png.decode(<<before::binary, byte + 1, rest::binary>>)
    end

    test "refuses chunks the writer does not make" do
      assert {:error, {:unexpected_chunk, "tEXt"}} =
               Png.decode(png(2, 2, 8, 0, <<0, 1, 2, 0, 3, 4>>, [chunk("tEXt", "key\0value")]))

      assert {:error, :trailing_data} = Png.decode(Png.grey(<<1, 2, 3, 4>>, 2, 2) <> <<0>>)
    end

    test "refuses the formats the writer does not make" do
      assert {:error, {:unsupported_format, %{colour_type: 6}}} =
               Png.decode(png(1, 1, 8, 6, <<0, 1, 2, 3, 4>>))

      assert {:error, {:unsupported_format, %{bit_depth: 16, colour_type: 2}}} =
               Png.decode(png(1, 1, 16, 2, <<0, 1, 2, 3, 4, 5, 6>>))

      assert {:error, {:unsupported_format, %{bit_depth: 4}}} =
               Png.decode(png(2, 1, 4, 0, <<0, 0x12>>))

      assert {:error, {:unsupported_format, %{interlace: 1}}} =
               Png.decode(png(1, 1, 8, 0, <<0, 1>>, [], 1))
    end

    test "refuses a filtered row" do
      assert {:error, {:unsupported_filter, 1}} =
               Png.decode(png(2, 2, 8, 0, <<0, 1, 2, 1, 3, 4>>))
    end

    test "refuses pixels that do not fill the image and data that is not zlib" do
      assert {:error, :bad_pixels} = Png.decode(png(2, 2, 8, 0, <<0, 1, 2, 0, 3>>))

      broken =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<2::32, 2::32, 8, 0, 0, 0, 0>>),
          chunk("IDAT", "not zlib"),
          chunk("IEND", <<>>)
        ])

      assert {:error, :bad_data} = Png.decode(broken)
    end
  end

  defp png(width, height, bit_depth, colour_type, scanlines, extra \\ [], interlace \\ 0) do
    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", <<width::32, height::32, bit_depth, colour_type, 0, 0, interlace>>),
      extra,
      chunk("IDAT", :zlib.compress(scanlines)),
      chunk("IEND", <<>>)
    ])
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
end
