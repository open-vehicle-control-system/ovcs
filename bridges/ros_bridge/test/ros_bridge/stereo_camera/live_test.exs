defmodule RosBridge.StereoCamera.LiveTest do
  use ExUnit.Case, async: true

  alias RosBridge.StereoCamera.Live

  @half_period 16_666_666

  describe "pair_offset/4" do
    test "measures right minus left against the nearest frame of the other camera" do
      assert Live.pair_offset(:right, 1_000_200_000, [1_000_000_000, 966_666_666], @half_period) ==
               200_000

      assert Live.pair_offset(:left, 1_000_200_000, [1_000_000_000, 966_666_666], @half_period) ==
               -200_000
    end

    test "pairs nothing farther than half a frame period, nor without frames" do
      assert Live.pair_offset(:right, 1_020_000_000, [1_000_000_000], @half_period) == nil
      assert Live.pair_offset(:right, 1_000_000_000, [], @half_period) == nil
    end
  end
end
