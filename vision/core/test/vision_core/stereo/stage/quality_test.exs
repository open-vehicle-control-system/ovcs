defmodule VisionCore.Stereo.Stage.QualityTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair}
  alias VisionCore.Stereo.Stage.Quality

  @context %{width: 64, height: 48}

  defp disparity(seed) do
    {sixteenths, _key} =
      Nx.Random.randint(Nx.Random.key(seed), -16, 1024, shape: {48, 64}, type: :s32)

    Nx.divide(sixteenths, 16)
  end

  defp segment do
    {:ok, state} = Quality.init([], @context)
    member = %{module: Quality, name: :quality, state: state}
    {:ok, segment} = NxSegment.build([member], @context, compiler: EXLA)
    segment
  end

  defp run(segment, disparity) do
    pair = %Pair{left_frame: nil, right_frame: nil, disparity: disparity}
    {:ok, pair, segment} = NxSegment.run(pair, segment)
    {Map.new(pair.metrics, fn {name, value, _unit} -> {name, value} end), segment}
  end

  test "measures the matched share, mean, spread and jitter of the disparity" do
    {first, second} = {disparity(1), disparity(2)}
    {_metrics, segment} = run(segment(), first)
    {metrics, _segment} = run(segment, second)

    values = Nx.to_flat_list(second)
    matched = Enum.filter(values, &(&1 > 0))
    mean = Enum.sum(matched) / length(matched)
    deviation = :math.sqrt(Enum.sum(Enum.map(matched, &((&1 - mean) ** 2))) / length(matched))

    both =
      for {a, b} <- Enum.zip(values, Nx.to_flat_list(first)), a > 0 and b > 0, do: abs(a - b)

    assert_in_delta metrics.valid, 100 * length(matched) / length(values), 1.0e-3
    assert_in_delta metrics.mean_disp, mean, 1.0e-3
    assert_in_delta metrics.std_disp, deviation, 1.0e-2
    assert_in_delta metrics.jitter, Enum.sum(both) / length(both), 1.0e-3
  end

  test "has no jitter on the first pair" do
    assert {%{jitter: +0.0}, _segment} = run(segment(), disparity(1))
  end
end
