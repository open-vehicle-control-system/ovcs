defmodule VisionCore.Stereo.Stage.SpeckleFilterTest do
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers, only: [run_stage: 4]

  alias VisionCore.Stereo.Stage

  defp filter(disparity, opts \\ []) do
    {height, width} = Nx.shape(disparity)
    context = %{height: height, width: width}
    run_stage(Stage.SpeckleFilter, opts, context, %{disparity: disparity}).disparity
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

  test "reads a disparity of 0 as unmatched: neither kept nor support for a neighbour" do
    zeros = Nx.broadcast(Nx.f32(0.0), {20, 30}) |> Nx.put_slice([9, 14], Nx.tensor([[0.5]]))
    assert filter(zeros) |> Nx.equal(-1.0) |> Nx.all() |> Nx.to_number() == 1
  end

  test "refuses settings out of range" do
    context = %{height: 2, width: 4}

    assert Stage.SpeckleFilter.init([min_support: 49], context) ==
             {:error, "min_support must be from 0 to 48, got 49"}

    assert Stage.SpeckleFilter.init([max_diff: 100], context) ==
             {:error, "max_diff must be from 0 to 8, got 100"}
  end
end
