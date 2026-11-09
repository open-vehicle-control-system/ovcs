defmodule VisionCore.Stereo.PackingTest do
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers, only: [context: 3, members: 2]

  alias VisionCore.Stereo.{Packing, Pipeline, Segment}

  test "pack then unpack gives the image back" do
    bytes = :rand.bytes(728 * 544)
    image = bytes |> Nx.from_binary(:u8) |> Nx.reshape({544, 728})

    packed = Packing.pack(bytes, 728, 544)
    assert Nx.shape(packed) == {544, 182}
    assert Nx.type(packed) == {:u, 32}

    unpacked = Nx.Defn.jit(&Packing.unpack(&1, {:u, 8})).(packed)
    assert unpacked == image
  end

  test "32-bit pixels packed on the device unpack into the image" do
    bytes = :rand.bytes(16 * 8)
    image = bytes |> Nx.from_binary(:u8) |> Nx.reshape({8, 16})

    packed = Nx.Defn.jit(&Packing.pack_image/1).(Nx.as_type(image, :s32))
    assert Packing.unpack_download(packed) == image
  end

  test "packed transfer refuses a width that is not a multiple of 4" do
    context = context(:identity, 730, 108)
    members = members(Pipeline.default_stages(), context)

    assert {:error, message} = Segment.entry_specs(members, context, packed: true)
    assert message =~ "multiple of 4"
  end
end
