defmodule VisionCore.Stereo.NxSegmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
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

  # Adds its live `step` to a total it carries from pair to pair.
  defmodule Count do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, 1}
    def requires, do: [:left]
    def provides, do: [:left]
    def params(step, _context), do: %{step: step}
    def carry(_step, _context), do: %{total: Nx.f32(0)}

    def step(tensors, params, _state) do
      total = Nx.add(params.total, params.step)

      tensors
      |> Map.put(:left, Nx.add(Nx.as_type(tensors.left, :f32), total))
      |> Map.put({:carry, :total}, total)
    end
  end

  # Count with `step` a live setting, and device work that takes a while.
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

  # Fills a tensor that only later stages on the device read.
  defmodule Scratch do
    @behaviour VisionCore.Stereo.NxStage
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left]
    def provides, do: [:left]
    def device_only, do: [:scratch]

    def step(tensors, _params, _state),
      do: Map.put(tensors, :scratch, Nx.multiply(tensors.left, 3))
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

  # Compiles to a function whose `:left` output is an UnreadableBuffer, read as its `:read` says.
  defmodule UnreadableDevice do
    @behaviour Nx.Defn.Compiler

    def __jit__(_key, _vars, _fun, _args, _opts), do: raise("only compiled")

    def __compile__(_key, _vars, _fun, opts) do
      left = %Nx.Tensor{
        data: %UnreadableBuffer{read: opts[:read]},
        shape: {2, 4},
        type: {:u, 8},
        names: [nil, nil]
      }

      fn _args -> [%{left: left}] end
    end

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

  test "passes each stage's params as inputs, and reload replaces them" do
    context = context(100.0)
    {:ok, segment} = NxSegment.build(members([AddOne, Offset], context), context, [])
    {:ok, pair, segment} = run(grey_pair(List.duplicate(0, 8)), segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [101.0]

    reloaded = context(5.0)
    segment = NxSegment.reload(segment, members([AddOne, Offset], reloaded), reloaded)
    {:ok, pair, _segment} = run(grey_pair(List.duplicate(0, 8)), segment)
    assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [6.0]
  end

  test "a new live setting applies from the next pair, keeping what the stages carry" do
    {:ok, segment} = NxSegment.build(members([AddOne, Count], context()), context(), [])
    {:ok, _pair, segment} = run(grey_pair(List.duplicate(0, 8)), segment)
    {:ok, _pair, segment} = run(grey_pair(List.duplicate(0, 8)), segment)

    segment = NxSegment.put_member_state(segment, 1, 10)
    {:ok, pair, _segment} = run(grey_pair(List.duplicate(0, 8)), segment)

    assert pair.left |> Nx.to_flat_list() |> Enum.uniq() == [13.0]
  end

  test "a pair back after a live change carries its values on, unless a reload came since" do
    {:ok, segment} = NxSegment.build(members([AddOne, Count], context()), context(), [])
    pair = grey_pair(List.duplicate(0, 8))
    {:ok, _outputs, replied, _done_ns} = reply(pair, segment)

    changed = NxSegment.put_member_state(segment, 1, 10)
    {:ok, next, _segment} = run(pair, NxSegment.merge_carry(changed, replied))
    assert next.left |> Nx.to_flat_list() |> Enum.uniq() == [12.0]

    reloaded = NxSegment.reload(segment, members([AddOne, Count], context()), context())
    {:ok, next, _segment} = run(pair, NxSegment.merge_carry(reloaded, replied))
    assert next.left |> Nx.to_flat_list() |> Enum.uniq() == [2.0]
  end

  test "leaves the tensors a stage fills for the device only out of its outputs" do
    {:ok, segment} = NxSegment.build(members([AddOne, Scratch], context()), context(), [])
    {:ok, outputs, _segment, _done_ns} = reply(grey_pair(List.duplicate(0, 8)), segment)

    assert Map.has_key?(outputs, :left)
    refute Map.has_key?(outputs, :scratch)
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

  test "waits for a pair's outputs up to a timeout" do
    {:ok, segment} = NxSegment.build(members([AddOne, Double], context()), context(), [])
    {:ok, ticket} = NxSegment.send_request(grey_pair([0, 1, 2, 3, 4, 5, 6, 7]), segment)

    assert {:ok, outputs, _segment, _done_ns} = NxSegment.await(ticket, segment, 5_000)
    assert Nx.to_list(outputs.left) == [[2, 4, 6, 8], [10, 12, 14, 16]]
  end

  test "returns what the device raises as the pair's error" do
    {:ok, segment} =
      NxSegment.build(members([AddOne], context()), context(),
        defn_options: [compiler: FailingDevice]
      )

    pair = grey_pair(List.duplicate(0, 8))
    error = %RuntimeError{message: "the device failed"}
    assert {:error, ^error} = run(pair, segment)

    {:ok, ticket} = NxSegment.send_request(pair, segment)
    assert {:error, ^error} = await_response(ticket, segment)
  end

  test "returns a download that fails as the pair's error, and one that does not end as a timeout" do
    pair = grey_pair(List.duplicate(0, 8))

    for {read, outcome} <- [
          raise: {:error, %RuntimeError{message: "the download failed"}},
          hang: :timeout
        ] do
      {:ok, segment} =
        NxSegment.build(members([AddOne], context()), context(),
          defn_options: [compiler: UnreadableDevice, read: read]
        )

      assert Segment.run(NxSegment, pair, segment, 200) == outcome
    end
  end

  test "takes its defn options among its build options, and refuses one it does not know" do
    assert {:ok, segment} =
             NxSegment.build(members([AddOne], context()), context(),
               defn_options: [compiler: EXLA]
             )

    assert NxSegment.compute(segment) == %{runs_on: :cpu, implementation: :nx, backend: :exla}

    assert NxSegment.build(members([AddOne], context()), context(), compiler: EXLA) ==
             {:error, "unknown build options [:compiler]"}
  end

  test "runs on Nx's evaluator without a compiler or with the evaluator, on another compiler else" do
    evaluator = %{runs_on: :cpu, implementation: :nx, backend: :evaluator}
    assert NxSegment.compute([]) == evaluator
    assert NxSegment.compute(compiler: Nx.Defn.Evaluator) == evaluator

    assert NxSegment.compute(compiler: FailingDevice) ==
             %{runs_on: :cpu, implementation: :nx, backend: nil}
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
      Pipeline.start_link(
        [
          name: :nx_segment_test,
          stages: stages,
          left_calibration_path: Path.join(@calibration, "stereo_left.yaml"),
          right_calibration_path: Path.join(@calibration, "stereo_right.yaml"),
          width: 4,
          height: 2
        ] ++ opts
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

    test "compiles with Nx's own defaults without defn options, whatever the app env says" do
      {:ok, pipeline} = start([AddOne, Fill])

      assert %{compute: %{implementation: :nx, backend: :evaluator}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :add_one))
    end

    test "keeps what a stage carries when a live setting changes while a pair is at the device" do
      {:ok, pipeline} = start([AddOne, SlowCount, Fill], defn_options: [compiler: EXLA])
      Pipeline.register_listener(pipeline, self())
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
      for stages <- [[AddOne, Fill], [LeftFrame, Double, Fill]] do
        {:ok, pipeline} = start(stages, defn_options: [compiler: FailingDevice])
        Pipeline.register_listener(pipeline, self())
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

    for {target, options} <- [c100: :c100_defn_options, rpi5: :rpi5_defn_options] do
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
