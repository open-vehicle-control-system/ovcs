defmodule VisionCore.Stereo.NxStageTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.NxStage

  defmodule Declared do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: []
    def provides, do: []
    def step(tensors, _params, _state), do: tensors
  end

  defmodule Undeclared do
    def step(tensors, _params, _state), do: tensors
  end

  @tag :tmp_dir
  test "reads the constants and kind of a stage not loaded yet", %{tmp_dir: dir} do
    [{module, binary}] =
      Code.compile_string("""
      defmodule VisionCore.Stereo.NxStageTest.NotLoaded do
        def native_kind, do: "speckle_filter"
        def native_constants, do: %{radius: 1}
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), binary)
    :code.delete(module)
    :code.purge(module)
    Code.prepend_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    assert NxStage.native_constants(module) == %{radius: 1}
    :code.delete(module)
    :code.purge(module)
    assert NxStage.native_kind(module) == "speckle_filter"
  end

  test "recognises an Nx stage by its behaviour, not by its functions" do
    assert NxStage.nx_stage?(Declared)
    refute NxStage.nx_stage?(Undeclared)
    refute NxStage.nx_stage?(VisionCore.Stereo.Stage.NoSuchStage)
  end

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
