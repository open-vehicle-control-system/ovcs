defmodule VisionCore.Stereo.Stage.QualityTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.Pair
  alias VisionCore.Stereo.Stage.Quality

  @context %{width: 64, height: 48, defn_options: [compiler: EXLA]}

  defp disparity(seed) do
    {sixteenths, _key} =
      Nx.Random.randint(Nx.Random.key(seed), -16, 1024, shape: {48, 64}, type: :s32)

    Nx.divide(sixteenths, 16)
  end

  defp run(state, disparity) do
    {:ok, pair, state} =
      Quality.run(%Pair{left_frame: nil, right_frame: nil, disparity: disparity}, state)

    {Map.new(pair.metrics, fn {name, value, _unit} -> {name, value} end), state}
  end

  test "measures the matched share, mean, spread and jitter of the disparity" do
    {:ok, state} = Quality.init([every_n: 1], @context)
    {first, second} = {disparity(1), disparity(2)}

    {_metrics, state} = run(state, first)
    {metrics, _state} = run(state, second)

    values = Nx.to_flat_list(second)
    matched = Enum.filter(values, &(&1 > 0))
    mean = Enum.sum(matched) / length(matched)
    deviation = :math.sqrt(Enum.sum(Enum.map(matched, &((&1 - mean) ** 2))) / length(matched))

    both =
      for {a, b} <- Enum.zip(values, Nx.to_flat_list(first)), a > 0 and b > 0, do: abs(a - b)

    assert_in_delta metrics.valid, 100 * length(matched) / length(values), 1.0e-3
    assert_in_delta metrics.mean_disp, mean, 1.0e-3
    assert_in_delta metrics.std_disp, deviation, 1.0e-3
    assert_in_delta metrics.jitter, Enum.sum(both) / length(both), 1.0e-3
  end

  test "has no jitter on the first measured pair" do
    {:ok, state} = Quality.init([every_n: 1], @context)
    assert {%{jitter: +0.0}, _state} = run(state, disparity(1))
  end

  test "adds no metrics between measured pairs" do
    {:ok, state} = Quality.init([every_n: 2], @context)
    pair = %Pair{left_frame: nil, right_frame: nil, disparity: Nx.broadcast(3.0, {48, 64})}

    {:ok, %Pair{metrics: []}, state} = Quality.run(pair, state)
    {:ok, %Pair{metrics: [_ | _]}, _state} = Quality.run(pair, state)
  end
end
