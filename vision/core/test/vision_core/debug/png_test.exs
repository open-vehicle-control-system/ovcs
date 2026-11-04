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
end
