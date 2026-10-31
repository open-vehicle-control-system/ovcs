defmodule VisionCore.Stereo.Stage.TemporalFilterTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair, Pipeline, Stage}

  @calibration Path.expand("../../../support/calibration", __DIR__)

  defp segment(opts) do
    context =
      Pipeline.context(
        left_calibration_path: Path.join(@calibration, "identity_left.yaml"),
        right_calibration_path: Path.join(@calibration, "identity_right.yaml"),
        width: 4,
        height: 2
      )

    {:ok, state} = Stage.TemporalFilter.init(opts, context)
    member = %{module: Stage.TemporalFilter, name: :temporal_filter, state: state}
    {:ok, segment} = NxSegment.build([member], context, compiler: EXLA)
    segment
  end

  defp run(segment, row) do
    disparity = Nx.tensor([row, row], type: :f32)

    {:ok, pair, segment} =
      NxSegment.run(%Pair{left_frame: nil, right_frame: nil, disparity: disparity}, segment)

    {pair.disparity[0] |> Nx.to_flat_list(), segment}
  end

  test "moves alpha of the way to a new disparity close to the previous one" do
    {first, segment} = run(segment(alpha: 0.4, delta: 1.0, hold: 0), [10.0, 10.0, -1.0, 10.0])
    assert first == [10.0, 10.0, -1.0, 10.0]

    {second, _segment} = run(segment, [10.5, 12.0, 10.0, -1.0])
    [smoothed, jumped, newly_matched, unmatched] = second
    assert_in_delta smoothed, 10.2, 1.0e-5
    assert jumped == 12.0
    assert newly_matched == 10.0
    assert unmatched == -1.0
  end

  test "smooths from the smoothed value, not the raw one" do
    {_, segment} = run(segment(alpha: 0.5, delta: 2.0), [10.0, 10.0, 10.0, 10.0])
    {_, segment} = run(segment, [11.0, 11.0, 11.0, 11.0])
    {[third | _], _segment} = run(segment, [11.0, 11.0, 11.0, 11.0])
    assert_in_delta third, 10.75, 1.0e-5
  end

  test "an alpha of 1 passes the disparity through" do
    {_, segment} = run(segment(alpha: 1.0), [10.0, 10.0, 10.0, 10.0])
    {second, _segment} = run(segment, [10.5, 10.5, 10.5, 10.5])
    assert second == [10.5, 10.5, 10.5, 10.5]
  end

  test "holds a pixel's last disparity for hold frames after it loses its match" do
    {_, segment} = run(segment(alpha: 1.0, hold: 2), [10.0, 10.0, 10.0, 10.0])
    {first_miss, segment} = run(segment, [-1.0, 10.0, 10.0, 10.0])
    {second_miss, segment} = run(segment, [-1.0, 10.0, 10.0, 10.0])
    {third_miss, segment} = run(segment, [-1.0, 10.0, 10.0, 10.0])
    {matched_again, _segment} = run(segment, [12.0, 10.0, 10.0, 10.0])

    assert hd(first_miss) == 10.0
    assert hd(second_miss) == 10.0
    assert hd(third_miss) == -1.0
    assert hd(matched_again) == 12.0
  end

  test "a hold of 0 lets holes through at once" do
    {_, segment} = run(segment(hold: 0), [10.0, 10.0, 10.0, 10.0])
    {[missed | _], _segment} = run(segment, [-1.0, 10.0, 10.0, 10.0])
    assert missed == -1.0
  end

  test "refuses settings out of range" do
    context = %{height: 2, width: 4}

    assert {:error, "temporal_filter alpha" <> _} =
             Stage.TemporalFilter.init([alpha: 0.0], context)

    assert {:error, "temporal_filter delta" <> _} =
             Stage.TemporalFilter.init([delta: -1], context)

    assert {:error, "temporal_filter hold" <> _} = Stage.TemporalFilter.init([hold: -1], context)
  end
end
