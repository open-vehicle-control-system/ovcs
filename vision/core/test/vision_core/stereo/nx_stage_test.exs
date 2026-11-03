defmodule VisionCore.Stereo.NxStageTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.NxStage

  # The axes of each sum image_sums/1 traces for `shape`, the first one first.
  defp sum_axes(shape) do
    expression = Nx.Defn.debug_expr(&NxStage.image_sums/1).(Nx.template(shape, :s32))
    reductions(expression, [])
  end

  defp reductions(%Nx.Tensor{data: %Nx.Defn.Expr{op: :sum, args: [inner, opts]}}, axes),
    do: reductions(inner, [opts[:axes] | axes])

  defp reductions(%Nx.Tensor{}, axes), do: axes

  test "sums each image of a stack in two reductions, down the columns first" do
    assert Nx.to_list(NxStage.image_sums(Nx.iota({2, 3, 4}))) == [66, 210]
    assert sum_axes({2, 3, 4}) == [[1], [1]]
  end

  test "sums one image in two reductions, along its rows first" do
    assert Nx.to_number(NxStage.image_sums(Nx.iota({3, 4}))) == 66
    assert sum_axes({3, 4}) == [[1], [0]]
  end
end
