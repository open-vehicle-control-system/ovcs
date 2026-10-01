defmodule RosBridge.StereoCamera.PersistenceFilterTest do
  use ExUnit.Case, async: true

  alias RosBridge.StereoCamera.PersistenceFilter

  defp cloud(points),
    do:
      for(
        {x, y, z} <- points,
        into: <<>>,
        do: <<x::little-float-32, y::little-float-32, z::little-float-32>>
      )

  defp points(binary),
    do:
      for(<<x::little-float-32, y::little-float-32, z::little-float-32 <- binary>>,
        do: {Float.round(x, 3), Float.round(y, 3), Float.round(z, 3)}
      )

  defp run(clouds, opts \\ []) do
    {outputs, _state} =
      Enum.map_reduce(clouds, PersistenceFilter.new(opts), fn c, state ->
        {kept, count, state} = PersistenceFilter.filter(state, cloud(c))
        {{points(kept), count}, state}
      end)

    outputs
  end

  test "keeps nothing until it has seen enough clouds" do
    assert [{[], 0}, {[], 0}, {[{0.0, 0.0, 2.0}], 1}] = run(List.duplicate([{0.0, 0.0, 2.0}], 3))
  end

  test "keeps a point every previous cloud saw" do
    assert {[{0.5, 0.1, 2.0}], 1} = run(List.duplicate([{0.5, 0.1, 2.0}], 4)) |> List.last()
  end

  test "drops a point that appears in alternate clouds" do
    clouds = [[{0.0, 0.0, 0.7}], [], [{0.0, 0.0, 0.7}], [], [{0.0, 0.0, 0.7}]]
    assert Enum.all?(run(clouds), fn {_points, count} -> count == 0 end)
  end

  test "drops a point no earlier cloud saw, keeps its stable neighbours" do
    stable = [{1.0, 0.0, 2.0}]
    [_, _, {kept, 1}] = run([stable, stable, [{-1.0, 0.0, 0.7} | stable]])
    assert kept == [{1.0, 0.0, 2.0}]
  end

  test "keeps a point that moves into the next voxel between clouds" do
    clouds = for k <- 0..4, do: [{0.0, 0.0, 2.0 - 0.06 * k}]
    assert {_points, 1} = List.last(run(clouds))
  end

  test "drops a point that jumps further than the neighbourhood" do
    clouds = for k <- 0..4, do: [{0.0, 0.0, 2.0 - 0.35 * k}]
    assert {[], 0} = List.last(run(clouds))
  end

  test "frames sets how many previous clouds must agree" do
    clouds = [[{0.0, 0.0, 1.0}], [], [{0.0, 0.0, 1.0}], [{0.0, 0.0, 1.0}]]
    assert {_points, 1} = List.last(run(clouds, frames: 1))
    assert {[], 0} = List.last(run(clouds, frames: 2))
  end
end
