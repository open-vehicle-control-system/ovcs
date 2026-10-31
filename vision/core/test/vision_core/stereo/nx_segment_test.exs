defmodule VisionCore.Stereo.NxSegmentTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{NxSegment, Pair, Pipeline}

  defmodule AddOne do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left_frame]
    def provides, do: [:left]
    def params(_state, _context), do: %{}
    def step(tensors, _params, _state), do: Map.put(tensors, :left, Nx.add(tensors.left_frame, 1))
  end

  defmodule Double do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]
    def provides, do: [:left]
    def params(_state, _context), do: %{}
    def step(tensors, _params, _state), do: Map.put(tensors, :left, Nx.multiply(tensors.left, 2))
  end

  defmodule Offset do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, context), do: {:ok, context.width}
    def requires, do: [:left]
    def provides, do: [:left]
    def params(_state, context), do: %{offset: context.focal_length_px}

    def step(tensors, params, _state),
      do: Map.put(tensors, :left, Nx.add(Nx.as_type(tensors.left, :f32), params.offset))
  end

  defmodule Halve do
    @behaviour VisionCore.Stereo.Stage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]
    def provides, do: [:left]
    def run(pair, state), do: {:ok, %{pair | left: Nx.quotient(pair.left, 2)}, state}
  end

  defmodule Fill do
    @behaviour VisionCore.Stereo.Stage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]

    def provides,
      do: [:right, :disparity, :disparity_range, :disparity_bytes, :depth]

    def run(pair, state), do: {:ok, pair, state}
  end

  defmodule NoCompiler do
    @behaviour Nx.Defn.Compiler

    def __jit__(_key, _vars, _fun, _args, _opts), do: no_compiler()
    def __compile__(_key, _vars, _fun, _opts), do: no_compiler()

    defp no_compiler,
      do: raise(NxIREE.CompileError, message: "compiling defn functions needs EXLA")

    def __partitions_options__(opts), do: [opts]
    def __to_backend__(_opts), do: {Nx.BinaryBackend, []}
  end

  @calibration Path.expand("../../support/calibration", __DIR__)

  defp context(focal_length_px \\ 100.0) do
    %{
      width: 4,
      height: 2,
      frame_width: 4,
      frame_height: 2,
      left_calibration: nil,
      right_calibration: nil,
      focal_length_px: focal_length_px,
      baseline_m: 0.06,
      principal_point: {2.0, 1.0}
    }
  end

  defp members(modules, context) do
    for module <- modules do
      {:ok, state} = module.init([], context)
      %{module: module, name: module, state: state}
    end
  end

  defp grey_pair(values) do
    frame = %Frame{
      label: "left",
      grey: :binary.list_to_bin(values),
      width: 4,
      height: 2,
      capture_ns: 0
    }

    %Pair{left_frame: frame, right_frame: frame}
  end

  test "runs consecutive steps as one function" do
    {:ok, segment} = NxSegment.build(members([AddOne, Double], context()), context(), [])
    {:ok, pair, _segment} = NxSegment.run(grey_pair([0, 1, 2, 3, 4, 5, 6, 7]), segment)

    assert Nx.to_list(pair.left) == [[2, 4, 6, 8], [10, 12, 14, 16]]
  end

  test "passes each stage's params as inputs, and reload replaces them" do
    context = context(100.0)
    {:ok, segment} = NxSegment.build(members([AddOne, Offset], context), context, [])
    {:ok, pair, segment} = NxSegment.run(grey_pair(List.duplicate(0, 8)), segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [101.0]

    reloaded = context(5.0)
    segment = NxSegment.reload(segment, members([AddOne, Offset], reloaded), reloaded)
    {:ok, pair, _segment} = NxSegment.run(grey_pair(List.duplicate(0, 8)), segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [6.0]
  end

  test "sends a pair without waiting, and recognises its outputs among other messages" do
    {:ok, segment} = NxSegment.build(members([AddOne, Double], context()), context(), [])
    {:ok, ticket} = NxSegment.send_request(grey_pair([0, 1, 2, 3, 4, 5, 6, 7]), segment)
    assert NxSegment.response(:other, ticket, segment) == :no_reply

    assert {:ok, outputs, _segment, done_ns} = await_response(ticket, segment)
    assert done_ns <= System.monotonic_time(:nanosecond)
    assert Nx.to_list(outputs.left) == [[2, 4, 6, 8], [10, 12, 14, 16]]
    refute_received {:DOWN, _ref, :process, _pid, _reason}
    assert NxSegment.member_times(segment) == []
  end

  test "returns a refused frame as the response to its request" do
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])
    frame = %Frame{label: "left", grey: <<0, 0, 0, 0>>, width: 2, height: 2, capture_ns: 0}
    {:ok, ticket} = NxSegment.send_request(%Pair{left_frame: frame, right_frame: frame}, segment)

    assert {:error, {:frame_size, :left_frame, {2, 2}, {2, 4}}} = await_response(ticket, segment)
  end

  defp await_response(ticket, segment) do
    receive do
      message ->
        case NxSegment.response(message, ticket, segment) do
          :no_reply -> await_response(ticket, segment)
          response -> response
        end
    after
      5_000 -> flunk("no response")
    end
  end

  @tag :jpeg
  test "decodes a JPEG frame" do
    start_supervised!(VisionCore.Jpeg)
    {:ok, jpeg} = VisionCore.Jpeg.encode(:binary.copy(<<40>>, 8), 4, 2, 1)
    frame = %Frame{label: "left", jpeg: jpeg, width: 4, height: 2, capture_ns: 0}
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])

    {:ok, pair, _segment} = NxSegment.run(%Pair{left_frame: frame, right_frame: frame}, segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.all?(&(&1 in 39..43))
  end

  @tag :jpeg
  test "refuses a JPEG frame that does not decode" do
    start_supervised!(VisionCore.Jpeg)
    frame = %Frame{label: "left", jpeg: <<0xFF, 0xD8>>, width: 4, height: 2, capture_ns: 0}
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])

    assert {:error, {:jpeg, :bad_request}, _segment} =
             NxSegment.run(%Pair{left_frame: frame, right_frame: frame}, segment)
  end

  test "refuses a frame of another size than the segment was compiled for" do
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])
    frame = %Frame{label: "left", grey: <<0, 0, 0, 0>>, width: 2, height: 2, capture_ns: 0}

    assert {:error, {:frame_size, :left_frame, {2, 2}, {2, 4}}, _segment} =
             NxSegment.run(%Pair{left_frame: frame, right_frame: frame}, segment)
  end

  test "without configured defn options, compiles with EXLA where it is loaded" do
    configured = Application.fetch_env!(:vision_core, :nx_defn_options)
    Application.delete_env(:vision_core, :nx_defn_options)
    on_exit(fn -> Application.put_env(:vision_core, :nx_defn_options, configured) end)

    assert NxSegment.defn_options(%{}) == [compiler: EXLA]
  end

  test "says where its defn options run a segment, and with what" do
    assert NxSegment.compute(NxSegment.c100_defn_options("cache")) ==
             %{runs_on: :gpu, implementation: :nx, backend: :vulkan}

    assert NxSegment.compute(NxSegment.rpi5_defn_options("cache")) ==
             %{runs_on: :cpu, implementation: :nx, backend: :llvm_cpu}

    assert NxSegment.compute(compiler: EXLA) ==
             %{runs_on: :cpu, implementation: :nx, backend: :exla}

    assert NxSegment.compute(compiler: EXLA, client: :cuda) ==
             %{runs_on: :gpu, implementation: :nx, backend: :exla}

    assert NxSegment.compute([]) == %{runs_on: :cpu, implementation: :nx, backend: :evaluator}
  end

  test "the Pi 5's options run on IREE's multithreaded CPU driver" do
    options = NxSegment.rpi5_defn_options("cache")
    assert options[:iree_runtime_options] == [device: "local-task://"]
  end

  test "a missing module names the cache command" do
    assert {:error, message} =
             NxSegment.build(members([AddOne], context()), context(), compiler: NoCompiler)

    assert message =~ "mix vision_core.nx_cache"
  end

  describe "in the pipeline" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp start(stages) do
      Pipeline.start_link(
        name: :nx_segment_test,
        stages: stages,
        left_calibration_path: Path.join(@calibration, "stereo_left.yaml"),
        right_calibration_path: Path.join(@calibration, "stereo_right.yaml"),
        width: 4,
        height: 2
      )
    end

    test "consecutive Nx stages form one segment, a CPU stage splits them" do
      {:ok, pipeline} = start([AddOne, Halve, Double, Fill])
      Pipeline.register_listener(pipeline, self())

      assert :sys.get_state(pipeline).stages |> Enum.map(& &1.name) ==
               [:add_one, :halve, :double, :fill]

      %Pair{left_frame: frame} = grey_pair([1, 3, 5, 7, 9, 11, 13, 15])
      Pipeline.submit(pipeline, frame, frame)

      assert_receive {:"$gen_cast", {:stereo_pair, %Pair{left: left}}}, 5_000
      assert Nx.to_list(left) == [[2, 4, 6, 8], [10, 12, 14, 16]]
    end

    test "names a segment after its members" do
      {:ok, pipeline} = start([AddOne, Double, Fill])
      assert :sys.get_state(pipeline).stages |> Enum.map(& &1.name) == [:"add_one+double", :fill]
    end
  end

  describe "on Vulkan through NxIREE" do
    @describetag :vulkan
    @describetag :tmp_dir

    test "a calibration reload compiles no new module", %{tmp_dir: dir} do
      {:ok, [device | _]} = NxIREE.list_devices("vulkan")

      defn_options = [
        compiler: NxIREE.Compiler,
        iree_module_cache: dir,
        iree_runtime_options: [device: device]
      ]

      context = context(100.0)
      {:ok, segment} = NxSegment.build(members([AddOne, Offset], context), context, defn_options)
      modules = Path.wildcard(Path.join(dir, "*"))
      assert modules != []

      reloaded = context(5.0)
      segment = NxSegment.reload(segment, members([AddOne, Offset], reloaded), reloaded)
      {:ok, pair, _segment} = NxSegment.run(grey_pair(List.duplicate(0, 8)), segment)

      assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [6.0]
      assert Path.wildcard(Path.join(dir, "*")) == modules
    end
  end

  describe "cache only" do
    @describetag :iree
    @describetag :tmp_dir

    for {target, options} <- [c100: :c100_defn_options, rpi5: :rpi5_defn_options] do
      test "writes the #{target} module without a device to load it on", %{tmp_dir: dir} do
        defn_options =
          NxSegment
          |> apply(unquote(options), [dir])
          |> Keyword.put(:cache_only, true)

        {:ok, segment} =
          NxSegment.build(members([AddOne, Double], context()), context(), defn_options)

        assert [_module] = Path.wildcard(Path.join(dir, "*.nxiree"))

        assert_raise RuntimeError, ~r/cache only/, fn ->
          NxSegment.run(grey_pair(List.duplicate(0, 8)), segment)
        end
      end
    end
  end
end
