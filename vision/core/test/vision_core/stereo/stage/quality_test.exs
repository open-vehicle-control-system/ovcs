defmodule VisionCore.Stereo.Stage.QualityTest do
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers, only: [run_nx: 3]

  alias VisionCore.Stereo.Stage.Quality

  @context %{width: 64, height: 48}

  defp disparity(seed) do
    {sixteenths, _key} =
      Nx.Random.randint(Nx.Random.key(seed), -16, 1024, shape: {48, 64}, type: :s32)

    Nx.divide(sixteenths, 16)
  end

  # The metrics of the last of `disparities`, run through one segment in order.
  defp metrics(disparities) do
    pairs = run_nx([Quality], @context, Enum.map(disparities, &%{disparity: &1}))
    Map.new(List.last(pairs).metrics, fn {name, value, _unit} -> {name, value} end)
  end

  test "measures the matched share, mean, spread and jitter of the disparity" do
    {first, second} = {disparity(1), disparity(2)}
    metrics = metrics([first, second])

    values = Nx.to_flat_list(second)
    matched = Enum.filter(values, &(&1 > 0))
    mean = Enum.sum(matched) / length(matched)
    deviation = :math.sqrt(Enum.sum(Enum.map(matched, &((&1 - mean) ** 2))) / length(matched))

    both =
      for {current, previous} <- Enum.zip(values, Nx.to_flat_list(first)),
          current > 0 and previous > 0,
          do: abs(current - previous)

    assert_in_delta metrics.matched_percent, 100 * length(matched) / length(values), 1.0e-3
    assert_in_delta metrics.mean_disparity_px, mean, 1.0e-3
    assert_in_delta metrics.spread_px, deviation, 1.0e-2
    assert_in_delta metrics.jitter_px, Enum.sum(both) / length(both), 1.0e-3
  end

  test "has no jitter on the first pair" do
    assert %{jitter_px: +0.0} = metrics([disparity(1)])
  end
end
