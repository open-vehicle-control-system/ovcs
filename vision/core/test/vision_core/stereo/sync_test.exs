defmodule VisionCore.Stereo.SyncTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.Sync

  @half_period_ns 16_666_666

  describe "pair_offset/4" do
    test "measures right minus left against the nearest frame of the other camera" do
      assert Sync.pair_offset(
               :right,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               200_000

      assert Sync.pair_offset(:left, 1_000_200_000, [1_000_000_000, 966_666_666], @half_period_ns) ==
               -200_000
    end

    test "pairs nothing farther than half a frame period, nor without frames" do
      assert Sync.pair_offset(:right, 1_020_000_000, [1_000_000_000], @half_period_ns) == nil
      assert Sync.pair_offset(:right, 1_000_000_000, [], @half_period_ns) == nil
    end
  end

  test "measures each pair of frames once, on the second of the two" do
    sync = Sync.new(30)

    {nil, sync} = Sync.add(sync, :left, 1_000_000_000, 0)
    {offset_ms, sync} = Sync.add(sync, :right, 1_000_200_000, 0)
    assert_in_delta offset_ms, 0.2, 1.0e-9

    {nil, sync} = Sync.add(sync, :left, 1_033_333_333, 33)
    {offset_ms, sync} = Sync.add(sync, :right, 1_033_133_333, 33)
    assert_in_delta offset_ms, -0.2, 1.0e-9

    assert %{pairs: 2, offset_max_ms: max_ms} = Sync.summary(sync, 40)
    assert_in_delta abs(max_ms), 0.2, 1.0e-9
  end

  test "summarises the recent pairs: the median, the largest from zero and the count" do
    sync =
      [0.1, 0.5, -0.9]
      |> Enum.with_index(1)
      |> Enum.reduce(Sync.new(30), fn {offset_ms, index}, sync ->
        at_ns = index * 33_333_333
        {nil, sync} = Sync.add(sync, :left, at_ns, 0)
        {_offset, sync} = Sync.add(sync, :right, at_ns + round(offset_ms * 1.0e6), 0)
        sync
      end)

    summary = Sync.summary(sync, 0)
    assert summary.pairs == 3
    assert_in_delta summary.offset_median_ms, 0.1, 1.0e-6
    assert_in_delta summary.offset_max_ms, -0.9, 1.0e-6
  end

  test "keeps the 150 most recent pairs" do
    sync =
      Enum.reduce(1..200, Sync.new(30), fn index, sync ->
        at_ns = index * 33_333_333
        {nil, sync} = Sync.add(sync, :left, at_ns, 0)
        {_offset, sync} = Sync.add(sync, :right, at_ns, 0)
        sync
      end)

    assert %{pairs: 150} = Sync.summary(sync, 0)
  end

  test "has no pair before the first, nor once the last formed more than two seconds ago" do
    assert Sync.summary(Sync.new(30), 0) == %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}

    {_none, sync} = Sync.add(Sync.new(30), :left, 1_000_000_000, 1_000)
    {_offset, sync} = Sync.add(sync, :right, 1_000_000_000, 1_000)

    assert %{pairs: 1} = Sync.summary(sync, 3_000)
    assert Sync.summary(sync, 3_001) == %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}
  end
end
