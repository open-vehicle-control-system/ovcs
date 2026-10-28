defmodule VisionCore.Ros2.Stereo.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.Stereo.Diagnostics

  @half_period_ns 16_666_666

  describe "pair_offset/4" do
    test "measures right minus left against the nearest frame of the other camera" do
      assert Diagnostics.pair_offset(
               :right,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               200_000

      assert Diagnostics.pair_offset(
               :left,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               -200_000
    end

    test "pairs nothing farther than half a frame period, nor without frames" do
      assert Diagnostics.pair_offset(
               :right,
               1_020_000_000,
               [1_000_000_000],
               @half_period_ns
             ) == nil

      assert Diagnostics.pair_offset(:right, 1_000_000_000, [], @half_period_ns) == nil
    end
  end
end
