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

  @computation [
    params: 2,
    step: 3,
    carry: 2,
    device_only: 0,
    compute: 1,
    native_kind: 0,
    native_constants: 0,
    native_settings: 1
  ]

  test "a stage computed by nx_stereo exports exactly its stage's computation callbacks" do
    modules =
      Enum.map(VisionCore.Stereo.Pipeline.default_stages(), &elem(&1, 0)) ++
        [VisionCore.Stereo.Stage.MedianFilter, VisionCore.Stereo.Stage.Decode]

    stages =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :stereo_stage, 0),
          do: module

    assert length(stages) == length(modules)

    for module <- stages, {name, arity} <- @computation do
      stage = module.stereo_stage()
      Code.ensure_loaded!(stage)

      assert function_exported?(module, name, arity) == function_exported?(stage, name, arity),
             "#{inspect(module)}.#{name}/#{arity} against #{inspect(stage)}"
    end
  end
end
