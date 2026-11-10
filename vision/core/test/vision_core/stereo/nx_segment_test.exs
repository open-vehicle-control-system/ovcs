defmodule VisionCore.Stereo.NxSegmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  import VisionCore.Stereo.TestHelpers,
    only: [calibration_path: 2, members: 2, start_pipeline: 1, frames_pair: 2, texture: 3]

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Stereo.{NxSegment, Pair, Pipeline, Segment}

  defmodule AddOne do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left_frame]
    def provides, do: [:left]
    def step(tensors, _params, _state), do: Map.put(tensors, :left, Nx.add(tensors.left_frame, 1))
  end

  defmodule Double do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]
    def provides, do: [:left]
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

  # Adds its live `step` to a total it carries from pair to pair, with device work that
  # takes a while.
  defmodule SlowCount do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, 1}
    def requires, do: [:left]
    def provides, do: [:left]
    def params(step, _context), do: %{step: step}
    def carry(_step, _context), do: %{total: Nx.f32(0)}
    def option_specs, do: [step: %{type: :integer, range: {1, 100}}]
    def options(step), do: %{step: step}
    def set_option(_step, :step, step), do: {:ok, step}

    def step(tensors, params, _state) do
      left = Nx.as_type(tensors.left, :f32)
      # A product XLA cannot fold away, since it depends on the pair.
      busy = Nx.iota({1_000, 1_000}, type: :f32) |> Nx.add(Nx.sum(left)) |> Nx.divide(1.0e6)
      total = busy |> Nx.dot(busy) |> Nx.sum() |> Nx.multiply(0) |> Nx.add(params.total)
      total = Nx.add(total, params.step)

      tensors
      |> Map.put(:left, Nx.add(left, total))
      |> Map.put({:carry, :total}, total)
    end
  end

  defmodule LeftFrame do
    @behaviour VisionCore.Stereo.Stage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left_frame]
    def provides, do: [:left]

    def run(pair, state) do
      {:ok, left} = Frame.to_tensor(pair.left_frame)
      {:ok, %{pair | left: left}, state}
    end
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

  # Outputs of three widths: a 32-bit float and a 16-bit integer image from the 8-bit one.
  defmodule Widen do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]
    def provides, do: [:disparity, :depth]

    def step(tensors, _params, _state) do
      tensors
      |> Map.put(:disparity, Nx.multiply(Nx.as_type(tensors.left, :f32), 0.5))
      |> Map.put(:depth, tensors.left |> Nx.as_type(:u16) |> Nx.multiply(300))
    end
  end

  # Compiles, and fails every call, as a device that errors on a pair.
  defmodule FailingDevice do
    @behaviour Nx.Defn.Compiler

    def __jit__(_key, _vars, _fun, _args, _opts), do: raise("the device failed")
    def __compile__(_key, _vars, _fun, _opts), do: fn _args -> raise "the device failed" end
    def __partitions_options__(opts), do: [opts]
    def __to_backend__(_opts), do: {Nx.BinaryBackend, []}
  end

  # A device buffer whose download raises, or never ends.
  defmodule UnreadableBuffer do
    defstruct [:read]

    def backend_transfer(%Nx.Tensor{data: %__MODULE__{read: :raise}}, _backend, _opts),
      do: raise("the download failed")

    def backend_transfer(%Nx.Tensor{data: %__MODULE__{read: :hang}}, _backend, _opts),
      do: Process.sleep(:infinity)
  end

  # Compiles to a function whose published bundle is an UnreadableBuffer, read as its `:read` says.
  defmodule UnreadableDevice do
    @behaviour Nx.Defn.Compiler

    def __jit__(_key, _vars, _fun, _args, _opts), do: raise("only compiled")

    def __compile__(_key, _vars, _fun, opts) do
      published = %Nx.Tensor{
        data: %UnreadableBuffer{read: opts[:read]},
        shape: {64},
        type: {:u, 32},
        names: [nil]
      }

      fn _args -> [%{published: published}] end
    end

    def __partitions_options__(opts), do: [opts]
    def __to_backend__(_opts), do: {Nx.BinaryBackend, []}
  end

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

  defp run(pair, segment), do: Segment.run(NxSegment, pair, segment, :infinity)

  # The reply to `pair`, its outputs left on the device.
  defp reply(pair, segment) do
    {:ok, ticket} = NxSegment.send_request(pair, segment)
    NxSegment.await(ticket, segment, 5_000)
  end

  test "runs consecutive steps as one function" do
    {:ok, segment} = NxSegment.build(members([AddOne, Double], context()), context(), [])
    {:ok, pair, _segment} = run(grey_pair([0, 1, 2, 3, 4, 5, 6, 7]), segment)

    assert Nx.to_list(pair.left) == [[2, 4, 6, 8], [10, 12, 14, 16]]
  end

  test "leaves a pair's outputs on the device as one tensor, which fills the pair once downloaded" do
    {:ok, segment} = NxSegment.build(members([AddOne, Widen], context()), context(), [])
    pair = grey_pair([0, 1, 2, 3, 4, 5, 6, 7])
    {:ok, outputs, segment, _done_ns} = reply(pair, segment)

    assert Map.keys(outputs) == [:published]
    assert Nx.type(outputs.published) == {:u, 32}

    {:ok, filled} = NxSegment.collect(pair, outputs, segment, 5_000)
    assert Nx.to_list(filled.left) == [[1, 2, 3, 4], [5, 6, 7, 8]]
    assert Nx.to_list(filled.disparity) == [[0.5, 1.0, 1.5, 2.0], [2.5, 3.0, 3.5, 4.0]]
    assert Nx.type(filled.depth) == {:u, 16}
    assert Nx.to_list(filled.depth) == [[300, 600, 900, 1200], [1500, 1800, 2100, 2400]]
  end

  test "takes every Nx stage to compile it, and none to compute natively" do
    assert NxSegment.accepts?(AddOne, nil, :nx)
    refute NxSegment.accepts?(AddOne, nil, :native)
    refute NxSegment.accepts?(Halve, nil, :nx)
  end

  test "refuses a frame of another size before it reaches the device" do
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])
    frame = %Frame{label: "left", grey: <<0, 0, 0, 0>>, width: 2, height: 2, capture_ns: 0}

    assert NxSegment.send_request(%Pair{left_frame: frame, right_frame: frame}, segment) ==
             {:error, {:frame_size, :left_frame, {2, 2}, {2, 4}}}
  end

  @tag :jpeg
  test "decodes a JPEG frame" do
    start_supervised!(VisionCore.Jpeg)
    {:ok, jpeg} = VisionCore.Jpeg.encode(:binary.copy(<<40>>, 8), 4, 2, 1)
    frame = %Frame{label: "left", jpeg: jpeg, width: 4, height: 2, capture_ns: 0}
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])

    {:ok, pair, _segment} = run(%Pair{left_frame: frame, right_frame: frame}, segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.all?(&(&1 in 39..43))
  end

  @tag :jpeg
  test "refuses a JPEG frame that does not decode" do
    start_supervised!(VisionCore.Jpeg)
    frame = %Frame{label: "left", jpeg: <<0xFF, 0xD8>>, width: 4, height: 2, capture_ns: 0}
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])

    assert {:refused, {:jpeg, :bad_request}} =
             run(%Pair{left_frame: frame, right_frame: frame}, segment)
  end

  test "refuses a frame of another size than the segment was compiled for" do
    {:ok, segment} = NxSegment.build(members([AddOne], context()), context(), [])
    frame = %Frame{label: "left", grey: <<0, 0, 0, 0>>, width: 2, height: 2, capture_ns: 0}

    assert {:refused, {:frame_size, :left_frame, {2, 2}, {2, 4}}} =
             run(%Pair{left_frame: frame, right_frame: frame}, segment)
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
             NxSegment.build(members([AddOne], context()), context(),
               defn_options: [compiler: NoCompiler]
             )

    assert message =~ "mix vision_core.nx_cache"
  end

  describe "in the pipeline" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp start(stages, opts \\ []) do
      start_pipeline(
        [
          name: :nx_segment_test,
          stages: stages,
          left_calibration_path: calibration_path(:stereo, :left),
          right_calibration_path: calibration_path(:stereo, :right),
          width: 4,
          height: 2
        ] ++ opts
      )
    end

    test "consecutive Nx stages form one segment, a CPU stage splits them" do
      {:ok, pipeline} = start([AddOne, Halve, Double, Fill])
      :ok = Outputs.subscribe({:stereo_pair, :nx_segment_test})

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

    test "compiles with Nx's own defaults without defn options, whatever the app env says" do
      {:ok, pipeline} = start([AddOne, Fill])

      assert %{compute: %{implementation: :nx, backend: :evaluator}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :add_one))
    end

    test "keeps what a stage carries when a live setting changes while a pair is at the device" do
      {:ok, pipeline} = start([AddOne, SlowCount, Fill], defn_options: [compiler: EXLA])
      :ok = Outputs.subscribe({:stereo_pair, :nx_segment_test})
      %Pair{left_frame: frame} = grey_pair(List.duplicate(0, 8))

      Pipeline.submit(pipeline, frame, frame)
      assert {:ok, %{step: 10}} = Pipeline.set_options(pipeline, :slow_count, step: 10)
      assert_receive :stereo_pipeline_ready, 10_000
      Pipeline.submit(pipeline, frame, frame)

      # 1 from AddOne, then the total: 1 after the first pair, 1 + 10 after the second.
      assert_receive {:"$gen_cast", {:stereo_pair, first}}, 10_000
      assert_receive {:"$gen_cast", {:stereo_pair, second}}, 10_000
      assert first.left |> Nx.to_flat_list() |> Enum.uniq() == [2.0]
      assert second.left |> Nx.to_flat_list() |> Enum.uniq() == [12.0]
    end

    test "logs a pair the device fails on, first or later in the stages, and takes the next one" do
      :ok = Outputs.subscribe({:stereo_pair, :nx_segment_test})

      for stages <- [[AddOne, Fill], [LeftFrame, Double, Fill]] do
        {:ok, pipeline} = start(stages, defn_options: [compiler: FailingDevice])
        %Pair{left_frame: frame} = grey_pair(List.duplicate(0, 8))

        log =
          capture_log(fn ->
            for _pair <- 1..2 do
              Pipeline.submit(pipeline, frame, frame)
              assert_receive :stereo_pipeline_ready, 5_000
            end
          end)

        assert log =~ "the device failed"
        refute_received {:"$gen_cast", {:stereo_pair, _pair}}
        assert Process.alive?(pipeline)
        GenServer.stop(pipeline)
      end
    end

    test "stops once the device fails ten pairs in a row, first or later in the stages" do
      for {stages, name} <- [{[AddOne, Fill], :add_one}, {[LeftFrame, Double, Fill], :double}] do
        {:ok, pipeline} = start(stages, defn_options: [compiler: FailingDevice])
        %Pair{left_frame: frame} = grey_pair(List.duplicate(0, 8))
        error = %RuntimeError{message: "the device failed"}

        capture_log(fn ->
          for _pair <- 1..9 do
            Pipeline.submit(pipeline, frame, frame)
            assert_receive :stereo_pipeline_ready, 5_000
          end

          Pipeline.submit(pipeline, frame, frame)
          assert_receive {:EXIT, ^pipeline, {:device_failing, ^name, ^error}}, 5_000
        end)

        refute_received :stereo_pipeline_ready
      end
    end

    test "counts no pair it refuses towards stopping" do
      {:ok, pipeline} = start([AddOne, Fill])
      small = %Frame{label: "left", grey: <<0, 0, 0, 0>>, width: 2, height: 2, capture_ns: 0}

      capture_log(fn ->
        for _pair <- 1..12 do
          Pipeline.submit(pipeline, small, small)
          assert_receive :stereo_pipeline_ready, 5_000
        end
      end)

      assert Process.alive?(pipeline)
    end

    test "logs a pair whose download fails and takes the next one; stops on one that does not end" do
      {:ok, pipeline} =
        start([AddOne, Fill],
          defn_options: [compiler: UnreadableDevice, read: :raise],
          flush_after_ms: 0
        )

      %Pair{left_frame: frame} = grey_pair(List.duplicate(0, 8))

      log =
        capture_log(fn ->
          for _pair <- 1..2 do
            Pipeline.submit(pipeline, frame, frame)
            assert_receive :stereo_pipeline_ready, 5_000
          end

          :sys.get_state(pipeline)
        end)

      assert log =~ "the download failed"
      assert Process.alive?(pipeline)
      GenServer.stop(pipeline)

      {:ok, pipeline} =
        start([AddOne, Fill],
          defn_options: [compiler: UnreadableDevice, read: :hang],
          flush_after_ms: 0,
          device_timeout_ms: 100
        )

      capture_log(fn ->
        Pipeline.submit(pipeline, frame, frame)
        assert_receive {:EXIT, ^pipeline, {:device_timeout, 100}}, 5_000
      end)
    end
  end

  describe "without byte buffers on the device" do
    test "the default stages give the same outputs as with byte buffers" do
      context = VisionCore.Stereo.TestHelpers.context(:identity, 192, 108)
      stages = Pipeline.default_stages(disparity: [paths: 3])

      outputs =
        for defn_options <- [[compiler: EXLA], [compiler: EXLA, byte_storage: false]] do
          {:ok, segment} =
            NxSegment.build(members(stages, context), context, defn_options: defn_options)

          frame_types =
            for {field, {_shape, type}} <- segment.specs,
                field in [:left_frame, :right_frame],
                do: type

          expected_type = if defn_options[:byte_storage] == false, do: {:u, 32}, else: {:u, 8}
          assert frame_types != [] and Enum.all?(frame_types, &(&1 == expected_type))

          {pairs, _segment} =
            Enum.map_reduce(1..3, segment, fn seed, segment ->
              image = texture(108, 200, seed)
              pair = frames_pair(image[[.., 0..191]], image[[.., 8..199]])
              {:ok, pair, segment} = run(%{pair | geometry: context}, segment)
              {pair, segment}
            end)

          pairs
        end

      [with_bytes, packed] = outputs

      for {expected, actual} <- Enum.zip(with_bytes, packed) do
        assert actual.left == expected.left
        assert actual.right == expected.right

        assert Nx.all_close(actual.disparity, expected.disparity, atol: 1.0e-4) ==
                 Nx.tensor(1, type: :u8)

        assert actual.cloud == expected.cloud
      end
    end

    test "a working width that is not a multiple of 4 is an error, not a raise" do
      context = VisionCore.Stereo.TestHelpers.context(:identity, 190, 108, {192, 108})
      members = members(Pipeline.default_stages(disparity: [paths: 3]), context)

      assert {:error, message} =
               NxSegment.build(members, context,
                 defn_options: [compiler: EXLA, byte_storage: false]
               )

      assert message =~ "multiple of 4"
    end
  end

  describe "with byte buffers on the device" do
    test "a working size of any width and an odd number of pixels runs" do
      context = VisionCore.Stereo.TestHelpers.context(:identity, 191, 107)
      members = members(Pipeline.default_stages(disparity: [paths: 3]), context)

      {:ok, segment} = NxSegment.build(members, context, defn_options: [compiler: EXLA])

      image = texture(107, 199, 1)
      pair = frames_pair(image[[.., 0..190]], image[[.., 8..198]])
      {:ok, pair, _segment} = run(%{pair | geometry: context}, segment)

      assert Nx.shape(pair.left) == {107, 191}
      assert byte_size(pair.depth) == 107 * 191 * 2
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

      {:ok, segment} =
        NxSegment.build(members([AddOne, Offset], context), context, defn_options: defn_options)

      modules = Path.wildcard(Path.join(dir, "*"))
      assert modules != []

      reloaded = context(5.0)
      segment = NxSegment.reload(segment, members([AddOne, Offset], reloaded), reloaded)
      {:ok, pair, _segment} = run(grey_pair(List.duplicate(0, 8)), segment)

      assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [6.0]
      assert Path.wildcard(Path.join(dir, "*")) == modules
    end
  end

  describe "cache only" do
    @describetag :iree
    @describetag :tmp_dir

    for {target, options} <- [
          c100: :c100_defn_options,
          rpi5: :rpi5_defn_options,
          ventuno_q: :ventuno_q_defn_options
        ] do
      test "writes the #{target} module without a device to load it on", %{tmp_dir: dir} do
        defn_options =
          NxSegment
          |> apply(unquote(options), [dir])
          |> Keyword.put(:cache_only, true)

        {:ok, segment} =
          NxSegment.build(members([AddOne, Double], context()), context(),
            defn_options: defn_options
          )

        assert [_module] = Path.wildcard(Path.join(dir, "*.nxiree"))

        assert {:error, %RuntimeError{message: "compiled for the module cache only"}} =
                 run(grey_pair(List.duplicate(0, 8)), segment)
      end
    end
  end
end
