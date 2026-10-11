defmodule VmsCore.Components.Nissan.FrameIntegrityTest do
  @moduledoc "The CRC and rolling counters closing Nissan Leaf frames."
  use ExUnit.Case, async: true
  alias VmsCore.Components.Nissan.FrameIntegrity

  test "the CRC is CRC-8 with polynomial 0x85" do
    assert FrameIntegrity.crc8("123456789") == 0x2A
  end

  test "the counter rolls over every four frames" do
    assert Enum.map(0..5, &FrameIntegrity.counter/1) == [0, 1, 2, 3, 0, 1]
  end

  test "the shifted counter sits in the top two bits, above 7" do
    assert Enum.map(0..4, &FrameIntegrity.shifted_counter/1) == [0x07, 0x47, 0x87, 0xC7, 0x07]
  end
end
