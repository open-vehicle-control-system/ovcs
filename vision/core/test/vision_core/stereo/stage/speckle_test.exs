defmodule VisionCore.Stereo.Stage.SpeckleTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair, Stage}

  defp filter(disparity, opts \\ []) do
    {height, width} = Nx.shape(disparity)
    context = %{height: height, width: width}
    {:ok, state} = Stage.Speckle.init(opts, context)
    member = %{module: Stage.Speckle, name: :speckle, state: state}
    {:ok, segment} = NxSegment.build([member], context, compiler: EXLA)

    {:ok, pair, _segment} =
      NxSegment.run(%Pair{left_frame: nil, right_frame: nil, disparity: disparity}, segment)

    pair.disparity
  end

  # A 20x30 surface at disparity 10 with a 3x3 blob at 30 inside it.
  defp scene do
    Nx.broadcast(Nx.f32(10.0), {20, 30})
    |> Nx.put_slice([8, 12], Nx.broadcast(Nx.f32(30.0), {3, 3}))
  end

  test "drops a blob too small to have support around it" do
    filtered = filter(scene())
    assert filtered[[8..10, 12..14]] |> Nx.equal(-1.0) |> Nx.all() |> Nx.to_number() == 1
  end

  test "keeps a surface up to its corners" do
    filtered = filter(scene())
    assert Nx.to_number(filtered[0][0]) == 10.0
    assert Nx.to_number(filtered[19][29]) == 10.0
    assert Nx.to_number(filtered[5][5]) == 10.0
  end

  test "keeps a blob with enough support once min_support is lower" do
    filtered = filter(scene(), min_support: 8)
    assert Nx.to_number(filtered[9][13]) == 30.0
  end

  test "leaves unmatched pixels unmatched" do
    disparity = Nx.put_slice(scene(), [0, 20], Nx.broadcast(Nx.f32(-1.0), {4, 4}))
    assert Nx.to_number(filter(disparity)[1][21]) == -1.0
  end

  test "refuses settings out of range" do
    context = %{height: 2, width: 4}
    assert {:error, "speckle min_support" <> _} = Stage.Speckle.init([min_support: 49], context)
    assert {:error, "speckle max_diff" <> _} = Stage.Speckle.init([max_diff: -1], context)
  end
end
