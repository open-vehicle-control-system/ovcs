defmodule VisionCore.Stereo.DepthCheckTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.DepthCheck

  @running %{left: %{present: true, fps: 35.0}, right: %{present: true, fps: 34.8}}

  defp window(overrides) do
    Map.merge(
      %{
        cameras: @running,
        depth_hz: 34.6,
        load_percent: 97.0,
        near: %{near_percent: 2.0, nearest_m: 1.4}
      },
      Map.new(overrides)
    )
  end

  # A pair whose disparity, over a 128-pixel range, is `values`, repeated down 8 rows.
  defp pair(values) do
    disparity = values |> Nx.tensor(type: :f32) |> Nx.tile([8, 1])

    %{
      disparity: disparity,
      disparity_scale: 1.0,
      disparity_range: %{min_disparity: 0, num_disparities: 128},
      geometry: %{focal_length_px: 896.0, baseline_m: 0.2}
    }
  end

  test "a unit keeping up with its cameras, its scene in range, has both checks ok" do
    checks = DepthCheck.check(window([]))

    for {_name, check} <- checks, do: assert(%{level: :ok, camera: nil, issues: []} = check)
  end

  test "rate counts the pairs the slower camera delivers that do not become depth, warning past 5%" do
    rate = DepthCheck.check(window(depth_hz: 30.0)).rate

    assert %{level: :warning, issues: [:pairs_dropped], camera_hz: 34.8, depth_hz: 30.0} = rate
    assert_in_delta rate.dropped_percent, 100 * (1 - 30.0 / 34.8), 1.0e-9
    assert_in_delta rate.gauge, rate.dropped_percent / 5, 1.0e-9

    assert %{level: :ok, dropped_percent: +0.0} = DepthCheck.check(window(depth_hz: 36.0)).rate
  end

  test "range warns past 15% of the matches in the nearest band" do
    range = DepthCheck.check(window(near: %{near_percent: 30.0, nearest_m: 1.4})).range

    assert %{level: :warning, issues: [:too_near], near_percent: 30.0, nearest_m: 1.4} = range
    assert_in_delta range.gauge, 2.0, 1.0e-9
  end

  test "keeps a raised issue until its figure falls below 0.8 of its threshold" do
    near = fn percent -> window(near: %{near_percent: percent, nearest_m: 1.4}) end
    raised = DepthCheck.check(near.(16.0))

    assert DepthCheck.check(near.(13.0), raised).range.issues == [:too_near]
    assert DepthCheck.check(near.(11.0), raised).range.issues == []
  end

  test "has nothing to judge without both cameras or a pair's disparity" do
    checks =
      DepthCheck.check(
        window(cameras: %{left: %{present: true, fps: 35.0}, right: %{present: false}}, near: nil)
      )

    for {_name, check} <- checks, do: assert(check == %{level: :off, camera: nil, issues: []})
  end

  test "near reads the share of matches in the top 15% of the range, and the nearest depth it measures" do
    # Of the first 8 columns, which the sample reads one in 8 of: 0 and 120 matter.
    values = [120.0] ++ List.duplicate(0.0, 7) ++ [10.0] ++ List.duplicate(0.0, 7)
    assert %{near_percent: 50.0, nearest_m: nearest} = DepthCheck.near(pair(values))
    assert_in_delta nearest, 896.0 * 0.2 / 128, 1.0e-9

    assert %{near_percent: +0.0} = DepthCheck.near(pair(List.duplicate(0.0, 16)))
    assert DepthCheck.near(%{disparity: nil}) == nil
  end

  test "lists every issue it raises" do
    assert DepthCheck.issues() == [:pairs_dropped, :too_near]
  end
end
