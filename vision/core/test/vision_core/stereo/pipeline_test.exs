defmodule VisionCore.Stereo.PipelineTest do
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers,
    only: [calibration_path: 2, start_pipeline: 1, stereo_match_path: 0, texture: 3]

  alias VisionCore.Outputs
  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pair, Pipeline}
  alias VisionCore.Stereo.{Stage, UnknownKind, VehicleDepth}

  # A CPU stage with a runtime setting and a build setting.
  defmodule Gain do
    @behaviour VisionCore.Stereo.Stage

    def init(opts, _context),
      do: {:ok, %{gain: Keyword.get(opts, :gain, 1), size: Keyword.get(opts, :size, 3)}}

    def requires, do: [:depth]
    def provides, do: [:depth]
    def run(pair, state), do: {:ok, pair, state}

    def option_specs,
      do: [
        gain: %{type: :integer, range: {1, 10}},
        size: %{type: :integer, values: [3, 5], applies: :build}
      ]

    def options(state), do: %{gain: state.gain, size: state.size}

    def set_option(state, :gain, gain) when gain in 1..10, do: {:ok, %{state | gain: gain}}
    def set_option(_state, :gain, gain), do: {:error, "gain out of range: #{inspect(gain)}"}
  end

  # A CPU stage declaring a live setting it has no set_option/3 to change.
  defmodule FixedGain do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, 1}
    def requires, do: [:depth]
    def provides, do: [:depth]
    def run(pair, state), do: {:ok, pair, state}
    def option_specs, do: [gain: %{type: :integer, range: {1, 10}}]
    def options(gain), do: %{gain: gain}
  end

  # A CPU stage between two native runs.
  defmodule Gain2D do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]
    def run(pair, state), do: {:ok, %{pair | disparity: Nx.multiply(pair.disparity, 1.0)}, state}
  end

  # A compiled stage that keeps the device busy and whose results take a while to collect.
  defmodule SlowFinish do
    @behaviour VisionCore.Stereo.NxStage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]

    def step(tensors, _params, _state) do
      busy = Nx.iota({2_500, 2_500}, type: :f32)
      busy = busy |> Nx.dot(busy) |> Nx.sum() |> Nx.multiply(0)
      Map.update!(tensors, :disparity, &Nx.add(&1, busy))
    end

    def finish(pair, _outputs, _state) do
      Process.sleep(200)
      pair
    end
  end

  # A compiled stage whose device work takes a while, on a product XLA cannot fold away.
  defmodule Busy do
    @behaviour VisionCore.Stereo.NxStage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]

    def step(tensors, _params, _state) do
      busy = Nx.iota({1_000, 1_000}, type: :f32) |> Nx.add(Nx.sum(tensors.disparity))
      busy = busy |> Nx.dot(busy) |> Nx.sum() |> Nx.multiply(0)
      Map.update!(tensors, :disparity, &Nx.add(&1, busy))
    end
  end

  # A CPU stage that reads and fills nothing.
  defmodule Pass do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: []
    def provides, do: []
    def run(pair, state), do: {:ok, pair, state}
  end

  # A CPU stage that reads the depth in metres, which Depth keeps on the device.
  defmodule DepthInMetres do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:depth_m]
    def provides, do: []
    def run(pair, state), do: {:ok, pair, state}
  end

  # A vehicle's stage of the same name as Quality.
  defmodule Vehicle.Quality do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: []
    def provides, do: []
    def run(pair, state), do: {:ok, pair, state}
  end

  # Nx stages EagerSegment takes.
  defmodule Tag do
    @behaviour VisionCore.Stereo.NxStage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]
    def step(tensors, _params, _state), do: Map.update!(tensors, :disparity, &Nx.add(&1, 0.0))
  end

  defmodule FrameTag do
    @behaviour VisionCore.Stereo.NxStage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left_frame]
    def provides, do: []
    def step(tensors, _params, _state), do: tensors
  end

  # A CPU stage that claims what the subscribers consume, after FrameTag.
  defmodule FillAll do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: []
    def provides, do: [:left, :right, :disparity, :disparity_range, :disparity_bytes, :depth]
    def run(pair, state), do: {:ok, pair, state}
  end

  # A compiler of its own, as EMLX or Torchx would be: Nx's evaluator under another name.
  defmodule OwnCompiler do
    @behaviour Nx.Defn.Compiler

    defdelegate __jit__(key, vars, fun, args, opts), to: Nx.Defn.Evaluator
    defdelegate __compile__(key, vars, fun, opts), to: Nx.Defn.Evaluator
    defdelegate __partitions_options__(opts), to: Nx.Defn.Evaluator
    defdelegate __to_backend__(opts), to: Nx.Defn.Evaluator
  end

  # A stage's callbacks without a stage behaviour.
  defmodule Undeclared do
    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:depth]
    def provides, do: [:depth]
    def step(tensors, _params, _state), do: tensors
  end

  # A backend of its own: runs Tag and FrameTag eagerly, in the pipeline's process, and
  # replies a moment later. It fails the pairs captured at the times its `:fail` option
  # lists, and tells its `:notify` process the capture time of each pair it is sent.
  defmodule EagerSegment do
    @behaviour VisionCore.Stereo.Segment

    alias VisionCore.Stereo.{NxStage, Segment}

    def build(members, context, opts) do
      {:ok,
       %{
         members: members,
         context: context,
         fail: Keyword.get(opts, :fail, []),
         notify: Keyword.get(opts, :notify)
       }}
    end

    def accepts?(module, _state, _compute), do: module in [Tag, FrameTag]

    def send_request(pair, segment) do
      capture_ns = pair.left_frame.capture_ns
      if segment.notify, do: send(segment.notify, {:sent, capture_ns})

      reply =
        if capture_ns in segment.fail,
          do: {:error, :failed},
          else: {:ok, steps(pair, segment), segment, now()}

      ref = make_ref()
      Process.send_after(self(), {ref, reply}, 20)
      {:ok, ref}
    end

    def response({ref, reply}, ref, _segment), do: reply
    def response(_message, _ref, _segment), do: :no_reply

    def await(ref, _segment, timeout) do
      receive do
        {^ref, reply} -> reply
      after
        timeout -> :timeout
      end
    end

    def collect(pair, outputs, segment, _timeout),
      do: {:ok, Segment.finish_members(segment.members, pair, outputs)}

    def depth, do: 1
    def merge_carry(current, _replied), do: current
    def member_times(_segment), do: []
    def compute(_segment), do: %{runs_on: :cpu, implementation: :nx, backend: :evaluator}
    def reload(segment, members, context), do: %{segment | members: members, context: context}

    def put_member_state(segment, index, state),
      do: %{segment | members: List.update_at(segment.members, index, &%{&1 | state: state})}

    defp steps(pair, segment) do
      tensors = Map.new(Segment.entry_fields(segment.members), &{&1, Map.fetch!(pair, &1)})

      Enum.reduce(segment.members, tensors, fn member, tensors ->
        params = NxStage.params(member.module, member.state, segment.context)
        member.module.step(tensors, params, member.state)
      end)
    end

    defp now, do: System.monotonic_time(:nanosecond)
  end

  defp start(stages, opts \\ []) do
    opts =
      if opts[:backends], do: opts, else: Keyword.put_new(opts, :defn_options, compiler: EXLA)

    start_pipeline(
      Keyword.merge(
        [
          name: :pipeline_test,
          stages: stages,
          left_calibration_path: calibration_path(:stereo, :left),
          right_calibration_path: calibration_path(:stereo, :right),
          width: 64,
          height: 48
        ],
        opts
      )
    )
  end

  # The pairs of the pipeline `start/2` starts, under any later restart too.
  defp subscribe_to_pairs, do: :ok = Outputs.subscribe({:stereo_pair, :pipeline_test})

  defp segment_modules(pipeline),
    do: Enum.map(Pipeline.segments(pipeline), &{&1.name, &1.module})

  # The Matcher again, running the stereo_match at `path`.
  defp restart_matcher(path) do
    stop_supervised!(Matcher)
    start_supervised!({Matcher, path: path})
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "starts with the default stages" do
    assert {:ok, _pipeline} = start(Pipeline.default_stages())
  end

  test "publishes its pairs under its name, apart from another pipeline's" do
    {:ok, pipeline} = start([FillAll])
    {:ok, other} = start([FillAll], name: :other_pipeline)
    subscribe_to_pairs()
    [left, right] = textured_pair(1)

    Pipeline.submit(other, left, right)
    assert_receive :stereo_pipeline_ready, 5_000
    refute_received {:"$gen_cast", {:stereo_pair, _pair}}

    Pipeline.submit(pipeline, left, right)
    assert_receive {:"$gen_cast", {:stereo_pair, %Pair{left_frame: %{capture_ns: 1}}}}, 5_000
  end

  test "refuses a stage whose inputs no stage before it provides" do
    stages = [Stage.Disparity, Stage.Decode, Stage.Depth]

    assert {:error, {%ArgumentError{message: message}, _}} = start(stages)
    assert message =~ "Disparity"
  end

  test "refuses a stage list that never produces depth" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start([Stage.Decode, Stage.Disparity])

    assert message =~ "depth"
  end

  test "refuses a stage outside Depth's segment that reads the depth Depth keeps on the device" do
    [rectification, sharpness, disparity | _rest] = Pipeline.default_stages()
    before_depth = [rectification, sharpness, disparity, Stage.Depth]

    for stages <- [before_depth ++ [DepthInMetres], before_depth ++ [Pass, Stage.PointCloud]] do
      assert {:error, {%ArgumentError{message: message}, _}} = start(stages)

      assert message =~ "needs :depth_m, which VisionCore.Stereo.Stage.Depth keeps on the device"
    end
  end

  defp without_compute(stages), do: Enum.map(stages, &Map.delete(&1, :compute))

  test "default_stages/1 passes overrides to the stage they name" do
    stages =
      Pipeline.default_stages(disparity: [num_disparities: 128], point_cloud: [decimation: 2])

    assert {Stage.Disparity, [num_disparities: 128]} in stages
    assert {Stage.PointCloud, [decimation: 2]} in stages
  end

  test "default_stages/1 lists the stages in pipeline order, with no median after Disparity's" do
    assert Enum.map(Pipeline.default_stages(), &elem(&1, 0)) == [
             Stage.Rectification,
             Stage.Sharpness,
             Stage.Disparity,
             Stage.SpeckleFilter,
             Stage.RowAlignment,
             Stage.TemporalFilter,
             Stage.Depth,
             Stage.PointCloud,
             Stage.Quality
           ]
  end

  test "default_stages/1 refuses an override for MedianFilter, which it does not list" do
    assert_raise ArgumentError,
                 ~r/^no default stage named :median_filter; they are :rectification, /,
                 fn -> Pipeline.default_stages(median_filter: [kernel_size: 3]) end
  end

  test "starts with MedianFilter added after Disparity, once" do
    stages = List.insert_at(Pipeline.default_stages(), 3, {Stage.MedianFilter, kernel_size: 3})
    {:ok, pipeline} = start(stages)
    names = pipeline |> Pipeline.stage_options() |> Enum.map(& &1.stage)

    assert Enum.slice(names, 2, 3) == [:disparity, :median_filter, :speckle_filter]
    assert Enum.count(names, &(&1 == :median_filter)) == 1
  end

  test "default_stages/1 refuses an override that names no stage" do
    assert_raise ArgumentError,
                 ~r/^no default stage named :disparty; they are :rectification, /,
                 fn ->
                   Pipeline.default_stages(
                     disparity: [paths: 3],
                     disparty: [num_disparities: 128]
                   )
                 end
  end

  test "refuses a stage that declares a live setting and has no set_option/3 to change it" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages() ++ [FixedGain])

    assert message ==
             "#{inspect(FixedGain)} declares the live settings [:gain] but no set_option/3"
  end

  test "refuses two stages of the same name, naming both modules" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages() ++ [Vehicle.Quality])

    assert message ==
             "#{inspect(Stage.Quality)} and #{inspect(Vehicle.Quality)} are both named " <>
               ":quality, after the last segment of their modules"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages() ++ [Stage.Quality])

    assert message == "#{inspect(Stage.Quality)} is listed twice among the stages"
  end

  test "recognises a stage by its behaviour, and refuses a module that declares none" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages() ++ [Undeclared])

    assert message ==
             "#{inspect(Undeclared)} implements neither VisionCore.Stereo.Stage " <>
               "nor VisionCore.Stereo.NxStage"
  end

  test "pins an Nx stage with compute: among its options, which its init/2 does not see" do
    {:ok, pipeline} = start(Pipeline.default_stages(sharpness: [compute: :nx]), compute: :native)

    assert segment_modules(pipeline) == [
             rectification: NativeSegment,
             sharpness: NxSegment,
             "disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality":
               NativeSegment
           ]

    GenServer.stop(pipeline)

    {:ok, pipeline} =
      start(Pipeline.default_stages(disparity: [compute: :native, matcher: :native, paths: 3]))

    assert segment_modules(pipeline) == [
             "rectification+sharpness": NxSegment,
             disparity: NativeSegment,
             "speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality": NxSegment
           ]
  end

  test "refuses a compute: pin the stage's own options contradict, on a CPU stage, or unknown" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(disparity: [matcher: :native, compute: :nx]))

    assert message ==
             "#{inspect(Stage.Disparity)} is pinned to compute: :nx, " <>
               "but its own options ask for :native"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages() ++ [{Gain, compute: :nx}])

    assert message == "#{inspect(Gain)} is not an Nx stage: compute: :nx does not apply to it"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(depth: [compute: :gpu]))

    assert message == "#{inspect(Stage.Depth)}: compute is :nx or :native, got :gpu"
  end

  test "refuses a stage asked to compute natively that no backend computes natively" do
    stages = [{Stage.Decode, compute: :native} | tl(Pipeline.default_stages())]
    assert {:error, {%ArgumentError{message: message}, _}} = start(stages)
    assert message == "no backend takes #{inspect(Stage.Decode)} to compute :native"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(disparity: [matcher: :native]),
               backends: [{NxSegment, defn_options: [compiler: EXLA]}]
             )

    assert message == "no backend takes #{inspect(Stage.Disparity)} to compute :native"
  end

  test "refuses frames smaller than the working size, compiled or computed natively" do
    for compute <- [:nx, :native] do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start(Pipeline.default_stages(),
                 compute: compute,
                 frame_width: 64,
                 frame_height: 36
               )

      assert message ==
               "#{inspect(Stage.Rectification)} cannot start: rectification only shrinks: " <>
                 "64x36 frames are smaller than the 64x48 working size"
    end
  end

  test "refuses to run a stage no backend computes natively on Nx's evaluator" do
    stages = [Stage.Decode | tl(Pipeline.default_stages())]

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(stages, compute: :native, defn_options: [])

    assert message ==
             "no backend computes #{inspect(Stage.Decode)} natively, and without a compiler " <>
               "in :defn_options it would run on Nx's evaluator"
  end

  test "compiles a stage no backend computes natively with a compiler other than Nx's evaluator" do
    stages = [Stage.Decode | tl(Pipeline.default_stages())]
    {:ok, pipeline} = start(stages, compute: :native, defn_options: [compiler: OwnCompiler])

    assert [{:decode, NxSegment}, {_native, NativeSegment}] = segment_modules(pipeline)
  end

  test "places each Nx stage in the first of its backends that takes it" do
    backends = [EagerSegment, NativeSegment, {NxSegment, defn_options: [compiler: EXLA]}]

    {:ok, pipeline} =
      start(Pipeline.default_stages(disparity: [paths: 3]) ++ [Tag], backends: backends)

    assert segment_modules(pipeline) == [
             "rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality":
               NxSegment,
             tag: EagerSegment
           ]

    assert %{compute: %{runs_on: :cpu, implementation: :nx, backend: :evaluator}} =
             Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :tag))

    subscribe_to_pairs()
    assert [%Pair{disparity: %Nx.Tensor{}}] = submit_when_ready(pipeline, [textured_pair(23)])
  end

  test "refuses :defn_options beside :backends, a backend that is no Segment, an Nx stage none takes" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(),
               backends: [NxSegment],
               defn_options: [compiler: EXLA]
             )

    assert message ==
             ":defn_options sets the default backends' NxSegment: " <>
               "with :backends, give it among NxSegment's options"

    assert {:ok, pipeline} =
             start(Pipeline.default_stages(),
               backends: [{NxSegment, defn_options: [compiler: EXLA]}],
               defn_options: nil
             )

    GenServer.stop(pipeline)

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(), backends: [Gain])

    assert message == "#{inspect(Gain)} is not a VisionCore.Stereo.Segment"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(), backends: [EagerSegment])

    assert message == "no backend takes #{inspect(Stage.Rectification)} to compute :nx"
  end

  test "stops once the device fails ten pairs in a row, a pair it gets through starting over" do
    fail = Enum.to_list(1..9) ++ Enum.to_list(11..20)
    {:ok, pipeline} = start([FrameTag, FillAll], backends: [{EagerSegment, fail: fail}])

    ExUnit.CaptureLog.capture_log(fn ->
      for seed <- 1..19 do
        [left, right] = textured_pair(seed)
        Pipeline.submit(pipeline, left, right)
        assert_receive :stereo_pipeline_ready, 5_000
      end

      [left, right] = textured_pair(20)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:EXIT, ^pipeline, {:device_failing, :frame_tag, :failed}}, 5_000
    end)
  end

  test "once stopped, sends no queued pair and tells no submitter it is ready" do
    backends = [{EagerSegment, fail: Enum.to_list(1..11), notify: self()}]
    {:ok, pipeline} = start([FrameTag, FillAll], backends: backends)

    ExUnit.CaptureLog.capture_log(fn ->
      for seed <- 1..9 do
        [left, right] = textured_pair(seed)
        Pipeline.submit(pipeline, left, right)
        assert_receive :stereo_pipeline_ready, 5_000
      end

      # The tenth failure stops it while the eleventh pair waits for the device.
      for seed <- 10..11 do
        [left, right] = textured_pair(seed)
        Pipeline.submit(pipeline, left, right)
      end

      assert_receive {:EXIT, ^pipeline, {:device_failing, :frame_tag, :failed}}, 5_000
    end)

    assert_received {:sent, 10}
    refute_received {:sent, 11}
    refute_received :stereo_pipeline_ready
  end

  test "gives the stages a context without the compiler's options" do
    context =
      Pipeline.context(
        left_calibration_path: calibration_path(:stereo, :left),
        right_calibration_path: calibration_path(:stereo, :right),
        width: 64,
        height: 48,
        defn_options: [compiler: EXLA]
      )

    refute Map.has_key?(context, :defn_options)
  end

  test "stops when a segment after the first does not answer in time" do
    stages = [Pass | Pipeline.default_stages(disparity: [paths: 3])] ++ [Busy]
    {:ok, pipeline} = start(stages, device_timeout_ms: 1)

    [left, right] = textured_pair(24)
    Pipeline.submit(pipeline, left, right)
    assert_receive {:EXIT, ^pipeline, {:device_timeout, 1}}, 10_000
  end

  test "refuses a stage option out of its spec, or that it does not declare" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(temporal_filter: [hold: 300]))

    assert message ==
             "#{inspect(Stage.TemporalFilter)} cannot start: hold must be from 0 to 10, got 300"

    assert {:error, {%ArgumentError{message: message}, _}} =
             start(Pipeline.default_stages(disparity: [num_disparity: 128]))

    assert message == "#{inspect(Stage.Disparity)} cannot start: num_disparity is not a setting"
  end

  test "lists each stage's settings and values in pipeline order" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])
    stages = Pipeline.stage_options(pipeline)

    assert Enum.map(stages, & &1.stage) == [
             :rectification,
             :sharpness,
             :disparity,
             :speckle_filter,
             :row_alignment,
             :temporal_filter,
             :depth,
             :point_cloud,
             :quality,
             :gain
           ]

    assert [
             %{
               stage: :rectification,
               module: Stage.Rectification,
               summary: "" <> _,
               specs: [right_row_offset: _]
             }
             | _
           ] = stages

    assert %{specs: [], values: %{}} = Enum.find(stages, &(&1.stage == :depth))

    for stage <- Enum.drop(stages, -1),
        do: assert(stage.compute == %{runs_on: :cpu, implementation: :nx, backend: :exla})

    assert List.last(stages).compute == %{runs_on: :cpu, implementation: :elixir, backend: nil}

    assert %{
             module: Gain,
             summary: "",
             explanation: nil,
             specs: [gain: %{applies: :live}, size: %{applies: :build}],
             values: %{gain: 1, size: 3}
           } = List.last(stages)
  end

  test "every stage the framework provides explains itself" do
    optional = [{Stage.Decode, []}, {Stage.MedianFilter, []}]

    for {module, _opts} <- optional ++ Pipeline.default_stages() do
      assert String.length(module.explanation()) > 0, "#{inspect(module)} has no explanation"
    end
  end

  test "sets a stage's live settings by stage" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])

    assert {:ok, %{gain: 3, size: 3}} = Pipeline.set_options(pipeline, :gain, gain: 3)

    assert %{values: %{gain: 3}} =
             Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :gain))
  end

  test "refuses a build setting, an unknown stage or setting, and an invalid value, changing nothing" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])

    assert Pipeline.set_options(pipeline, :gain, gain: 2, size: 5) ==
             {:error, "gain.size is fixed when the stage starts"}

    assert {:error, "no stereo stage" <> _} = Pipeline.set_options(pipeline, :nope, gain: 2)

    assert Pipeline.set_options(pipeline, :gain, block_size: 7) ==
             {:error, "gain.block_size is not a setting"}

    assert Pipeline.set_options(pipeline, :disparity, [{"p1", 2}]) ==
             {:error, ~s(disparity."p1" is not a setting)}

    assert {:error, "gain out of range" <> _} =
             Pipeline.set_options(pipeline, :gain, gain: 2, gain: 20)

    assert {:error, "disparity.paths" <> _} = Pipeline.set_options(pipeline, :disparity, paths: 3)

    assert Pipeline.set_options(pipeline, :disparity, p1: 4, p1: 70) ==
             {:error, "p1 must be below p2 (64), got 70"}

    values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
    assert values.gain == %{gain: 1, size: 3}
    assert %{p1: 8, paths: 8} = values.disparity
  end

  test "changes the match penalties without compiling again" do
    {:ok, pipeline} = start(Pipeline.default_stages())
    [%{state: segment}] = segments(pipeline)

    assert {:ok, %{p1: 4, p2: 40, uniqueness: 1.2}} =
             Pipeline.set_options(pipeline, :disparity, p1: 4, p2: 40, uniqueness: 1.2)

    [%{state: changed}] = segments(pipeline)
    assert changed.function == segment.function
    match = Enum.find(changed.params, fn {_index, params} -> Map.has_key?(params, :p1) end)
    assert {_index, %{p1: p1, p2: p2} = params} = match
    assert params |> Map.keys() |> Enum.sort() == [:p1, :p2, :uniqueness]
    assert {Nx.to_number(p1), Nx.to_number(p2)} == {4.0, 40.0}

    assert Pipeline.set_options(pipeline, :disparity, p1: 40) ==
             {:error, "p1 must be below p2 (40), got 40"}

    assert Pipeline.set_options(pipeline, :disparity, p2: 100) ==
             {:error, "p2 must be from 1 to 79, got 100"}

    assert %{values: %{p1: 4}} =
             Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :disparity))
  end

  defp segments(pipeline),
    do: pipeline |> Pipeline.segments() |> Enum.filter(&(&1.module == NxSegment))

  describe "with a compiled segment first" do
    defp textured_pair(seed) do
      noise = texture(48, 76, seed)

      for {label, image} <- [left: noise[[.., 0..63]], right: noise[[.., 12..75]]] do
        %VisionCore.Camera.Frame{
          label: to_string(label),
          grey: Nx.to_binary(image),
          width: 64,
          height: 48,
          capture_ns: seed
        }
      end
    end

    test "is ready for the next pair before it publishes the previous one" do
      {:ok, pipeline} = start(Pipeline.default_stages())
      subscribe_to_pairs()

      [left, right] = textured_pair(1)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      refute_received {:"$gen_cast", {:stereo_pair, _}}

      [left, right] = textured_pair(2)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = first}}, 60_000
      assert first.left_frame.capture_ns == 1
      assert_receive :stereo_pipeline_ready, 60_000
    end

    test "stops when the device does not answer in time, for its supervisor to restart it" do
      {:ok, pipeline} = start(Pipeline.default_stages(), device_timeout_ms: 1)

      [left, right] = textured_pair(4)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:EXIT, ^pipeline, {:device_timeout, 1}}, 60_000
    end

    test "publishes the last pair when no other follows" do
      {:ok, pipeline} = start(Pipeline.default_stages())
      subscribe_to_pairs()

      [left, right] = textured_pair(3)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = pair}}, 1_000
      assert pair.left_frame.capture_ns == 3
    end

    test "publishes pairs taken as soon as it is ready in order, with the results of one at a time" do
      assert_overlapped_matches_one_at_a_time([])
    end

    test "counts device time once while a pair is collected during the next one's device work" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]) ++ [SlowFinish], flush_after_ms: 0)

      subscribe_to_pairs()
      submit_when_ready(pipeline, [textured_pair(40)])

      start_ms = System.monotonic_time(:millisecond)
      pairs = submit_when_ready(pipeline, Enum.map(41..48, &textured_pair/1))
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      assert pairs |> Enum.map(& &1.device_ms) |> Enum.sum() <= elapsed_ms
    end

    test "does not count the wait for the next pair as device time" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]), flush_after_ms: 5_000)

      subscribe_to_pairs()
      submit_when_ready(pipeline, [textured_pair(50)])

      [left, right] = textured_pair(51)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      Process.sleep(500)
      [left, right] = textured_pair(52)
      Pipeline.submit(pipeline, left, right)

      assert_receive {:"$gen_cast", {:stereo_pair, %{left_frame: %{capture_ns: 51}} = pair}},
                     60_000

      assert pair.device_ms < 500
    end

    test "logs a pair the segment refuses and takes the next one" do
      assert_refused_pair_skipped([])
    end

    test "sends a pair submitted before it is ready once the previous one is back" do
      assert_early_pair_sent_later(2, [])
    end

    test "times the segment under its name" do
      assert_timed(
        [
          :"rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
        ],
        []
      )
    end
  end

  # Submits each pair once the pipeline is ready for it, as the Pairer does.
  defp submit_when_ready(pipeline, frames) do
    for [left, right] <- frames do
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
    end

    for _frames <- frames do
      assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
      pair
    end
  end

  defp assert_overlapped_matches_one_at_a_time(opts) do
    frames = Enum.map(10..13, &textured_pair/1)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    subscribe_to_pairs()
    one_at_a_time = Enum.flat_map(frames, &submit_when_ready(pipeline, [&1]))
    GenServer.stop(pipeline)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    overlapped = submit_when_ready(pipeline, frames)

    assert Enum.map(overlapped, & &1.left_frame.capture_ns) == Enum.to_list(10..13)

    for {got, want} <- Enum.zip(overlapped, one_at_a_time) do
      assert got.disparity_bytes == want.disparity_bytes
      assert got.depth == want.depth
      assert got.metrics == want.metrics
    end
  end

  # One pair more than the device takes, submitted without waiting for the pipeline to be ready.
  defp assert_early_pair_sent_later(count, opts) do
    frames = Enum.map(30..(30 + count - 1), &textured_pair/1)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    subscribe_to_pairs()
    one_at_a_time = Enum.flat_map(frames, &submit_when_ready(pipeline, [&1]))
    GenServer.stop(pipeline)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    for [left, right] <- frames, do: Pipeline.submit(pipeline, left, right)

    early =
      for _frames <- frames do
        assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
        pair
      end

    assert Enum.map(early, & &1.left_frame.capture_ns) == Enum.to_list(30..(30 + count - 1))
    assert Enum.map(early, & &1.disparity_bytes) == Enum.map(one_at_a_time, & &1.disparity_bytes)
    assert_receive :stereo_pipeline_ready, 60_000
  end

  defp assert_refused_pair_skipped(opts) do
    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    subscribe_to_pairs()
    [left, right] = textured_pair(20)
    small = %{left | width: 32, height: 48, grey: binary_part(left.grey, 0, 32 * 48)}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Pipeline.submit(pipeline, small, small)
        assert_receive :stereo_pipeline_ready, 60_000
        :sys.get_state(pipeline)
      end)

    assert log =~ "frame_size"
    refute_received {:"$gen_cast", {:stereo_pair, _pair}}
    assert [%{left_frame: %{capture_ns: 20}}] = submit_when_ready(pipeline, [[left, right]])
  end

  defp assert_timed(names, opts) do
    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    subscribe_to_pairs()
    submit_when_ready(pipeline, [textured_pair(21)])
    timed = Map.keys(:sys.get_state(pipeline).timer.stages)

    assert names -- timed == []
  end

  describe "with the native matcher" do
    @describetag :stereo_match

    setup do
      start_supervised!({Matcher, path: stereo_match_path()})
      :ok
    end

    defp names(pipeline), do: Enum.map(:sys.get_state(pipeline).stages, & &1.name)

    defp receive_pair(pipeline, [left, right]) do
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = pair}}, 60_000
      pair
    end

    test "runs Disparity between two compiled segments, under its own name and settings" do
      {:ok, compiled} = start(Pipeline.default_stages())
      compiled_options = Pipeline.stage_options(compiled)
      GenServer.stop(compiled)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native]))

      assert names(pipeline) == [
               :"rectification+sharpness",
               :disparity,
               :"speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      options = Pipeline.stage_options(pipeline)
      assert without_compute(options) == without_compute(compiled_options)

      for stage <- options do
        implementation = if stage.stage == :disparity, do: :rust, else: :nx
        assert stage.compute.implementation == implementation
      end
    end

    test "produces a disparity and depth" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native, paths: 3]))
      subscribe_to_pairs()

      pair = receive_pair(pipeline, textured_pair(5))

      assert %Nx.Tensor{shape: {48, 64}, type: {:f, 32}} = pair.disparity
      assert pair.disparity_scale == 1.0

      assert %{min_disparity: 0, num_disparities: 64, block_size: 9, block_height: 7} =
               pair.disparity_range

      assert pair.disparity |> Nx.greater(0) |> Nx.sum() |> Nx.to_number() > 0
      assert byte_size(pair.depth) == 48 * 64 * 2
    end

    test "applies a live p1 change from the next pair, as NxStereo.sgm/3 would" do
      stages = [Stage.Rectification, {Stage.Disparity, matcher: :native, paths: 3}, Stage.Depth]
      {:ok, pipeline} = start(stages)
      subscribe_to_pairs()
      frames = textured_pair(6)
      first = receive_pair(pipeline, frames)

      assert {:ok, %{p1: 2}} = Pipeline.set_options(pipeline, :disparity, p1: 2)
      second = receive_pair(pipeline, frames)

      # NxStereo.sgm/3 as the Disparity stage reads it: a match at disparity 0 is unmatched.
      reference = fn p1 ->
        sgm = &NxStereo.sgm(&1, &2, disparities: 64, paths: 3, p1: p1, p2: 64)
        disparity = Nx.Defn.jit_apply(sgm, [second.left, second.right], compiler: EXLA)
        disparity |> Nx.greater(0) |> Nx.select(disparity, -1.0) |> Nx.to_binary()
      end

      assert Nx.to_binary(second.disparity) == reference.(2)
      assert Nx.to_binary(first.disparity) == reference.(8)
      assert first.disparity != second.disparity
    end

    test "stays native across a calibration reload" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native]))
      {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)

      assert :ok = Pipeline.reload_calibration(pipeline)
      assert :disparity in names(pipeline)

      assert %{values: %{p1: 5}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :disparity))
    end
  end

  describe "computing natively" do
    @describetag :stereo_match

    setup do
      start_supervised!({Matcher, path: stereo_match_path()})
      :ok
    end

    test "runs the default stages as one native segment, under their names and settings" do
      {:ok, compiled} = start(Pipeline.default_stages())
      compiled_options = Pipeline.stage_options(compiled)
      GenServer.stop(compiled)

      {:ok, pipeline} = start(Pipeline.default_stages(), compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      options = Pipeline.stage_options(pipeline)
      assert without_compute(options) == without_compute(compiled_options)

      for stage <- options,
          do: assert(stage.compute == %{runs_on: :cpu, implementation: :rust, backend: nil})
    end

    test "runs the MedianFilter a vehicle adds as a member of the native segment" do
      stages =
        List.insert_at(
          Pipeline.default_stages(disparity: [paths: 3]),
          3,
          {Stage.MedianFilter, kernel_size: 3}
        )

      {:ok, pipeline} = start(stages, compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity+median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      subscribe_to_pairs()
      assert byte_size(receive_pair(pipeline, textured_pair(6)).depth) == 48 * 64 * 2
    end

    test "fills every field the subscribers read" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      subscribe_to_pairs()

      pair = receive_pair(pipeline, textured_pair(7))

      assert %Nx.Tensor{shape: {48, 64}, type: {:u, 8}} = pair.left
      assert %Nx.Tensor{shape: {48, 64}, type: {:u, 8}} = pair.right
      assert %Nx.Tensor{shape: {48, 64}, type: {:f, 32}} = pair.disparity
      assert pair.disparity_bytes == Nx.to_binary(pair.disparity)
      assert byte_size(pair.depth) == 48 * 64 * 2
      assert {12, 16} = pair.cloud_size
      assert byte_size(pair.cloud) == 12 * 16 * 12
      assert %{left: left, right: right} = pair.sharpness
      assert left > 0 and right > 0

      assert [:matched_percent, :mean_disparity_px, :spread_px, :jitter_px] --
               Enum.map(pair.metrics, &elem(&1, 0)) ==
               []

      assert pair.device_ms > 0
    end

    test "runs a vehicle's stage that declares a native kind in the native segment" do
      stages =
        Enum.map(Pipeline.default_stages(disparity: [paths: 3]), fn
          {Stage.Depth, opts} -> {VehicleDepth, opts}
          stage -> stage
        end)

      {:ok, pipeline} = start(stages, compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+vehicle_depth+point_cloud+quality"
             ]

      subscribe_to_pairs()
      assert byte_size(receive_pair(pipeline, textured_pair(8)).depth) == 48 * 64 * 2
    end

    test "compiles a stage no backend computes natively, and logs where each run computes" do
      stages = [Stage.Decode | tl(Pipeline.default_stages(disparity: [paths: 3]))]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pipeline} = start(stages, compute: :native)
          send(self(), {:started, pipeline})
        end)

      assert_received {:started, pipeline}

      native =
        :"sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"

      assert segment_modules(pipeline) == [{:decode, NxSegment}, {native, NativeSegment}]
      assert log =~ "stages: decode (cpu, nx, exla) → #{native} (cpu, rust))"

      subscribe_to_pairs()
      assert byte_size(receive_pair(pipeline, textured_pair(8)).depth) == 48 * 64 * 2
    end

    test "runs a stage without a native implementation between two native segments" do
      stages = List.insert_at(Pipeline.default_stages(), 3, Gain2D)
      {:ok, pipeline} = start(stages, compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity",
               :gain2_d,
               :"speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      subscribe_to_pairs()
      assert byte_size(receive_pair(pipeline, textured_pair(8)).depth) == 48 * 64 * 2
    end

    test "compiles a stage that asks for Nx" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [matcher: :nx]), compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness",
               :disparity,
               :"speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      assert [NativeSegment, NxSegment, NativeSegment] ==
               Enum.map(:sys.get_state(pipeline).stages, & &1.module)
    end

    test "applies a live setting from the next pair, and keeps it across a calibration reload" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      subscribe_to_pairs()
      frames = textured_pair(9)
      first = receive_pair(pipeline, frames)

      assert {:ok, %{right_row_offset: 2.0}} =
               Pipeline.set_options(pipeline, :rectification, right_row_offset: 2.0)

      second = receive_pair(pipeline, frames)
      assert Nx.to_binary(second.left) == Nx.to_binary(first.left)
      assert Nx.to_binary(second.right[[0..40, ..]]) == Nx.to_binary(first.right[[2..42, ..]])

      assert :ok = Pipeline.reload_calibration(pipeline)

      assert %{values: %{right_row_offset: 2.0}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :rectification))

      third = receive_pair(pipeline, frames)
      assert Nx.to_binary(third.right) == Nx.to_binary(second.right)
    end

    test "takes a second pair while the first is at the Port, with the results of one at a time" do
      frames = Enum.map(10..13, &textured_pair/1)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      subscribe_to_pairs()
      one_at_a_time = Enum.map(frames, &receive_pair(pipeline, &1))
      GenServer.stop(pipeline)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      [[left, right] | later] = frames
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 1_000

      overlapped =
        Enum.map(later, fn [left, right] ->
          Pipeline.submit(pipeline, left, right)

          # The pipeline is ready for another pair once the earlier one is out.
          assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
          assert_receive :stereo_pipeline_ready, 60_000
          pair
        end)

      assert_receive {:"$gen_cast", {:stereo_pair, last}}, 60_000
      overlapped = overlapped ++ [last]

      assert Enum.map(overlapped, & &1.left_frame.capture_ns) == Enum.to_list(10..13)

      for {got, want} <- Enum.zip(overlapped, one_at_a_time) do
        assert got.disparity_bytes == want.disparity_bytes
        assert got.depth == want.depth
        assert got.metrics == want.metrics
      end
    end

    test "publishes pairs taken as soon as it is ready in order, with the results of one at a time, natively" do
      assert_overlapped_matches_one_at_a_time(compute: :native)
    end

    test "logs a pair the segment refuses and takes the next one, natively" do
      assert_refused_pair_skipped(compute: :native)
    end

    test "sends a pair submitted before it is ready once the oldest one is back" do
      assert_early_pair_sent_later(3, compute: :native)
    end

    test "times the segment and each member under their names" do
      segment =
        :"rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"

      members = segment |> to_string() |> String.split("+") |> Enum.map(&String.to_atom/1)
      assert_timed([segment | members], compute: :native)
    end

    test "publishes a pair once it is back when no other is at the Port" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]),
          compute: :native,
          flush_after_ms: 60_000
        )

      subscribe_to_pairs()
      [left, right] = textured_pair(22)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %{left_frame: %{capture_ns: 22}}}}, 10_000
    end

    # A stereo_match that reads its requests and never answers, until `dir` holds an `answer`
    # file: started from then on, it is the real one.
    defp silent_port(dir) do
      silent = Path.join(dir, "stereo_match")

      File.write!(silent, """
      #!/bin/sh
      if [ -e "#{Path.join(dir, "answer")}" ]; then exec "#{stereo_match_path()}" "$@"; fi
      exec cat > /dev/null
      """)

      File.chmod!(silent, 0o755)
      restart_matcher(silent)
    end

    test "stops at its first pair when the Port refuses its configuration, saying why" do
      stages = List.insert_at(Pipeline.default_stages(disparity: [paths: 3]), 3, UnknownKind)
      {:ok, pipeline} = start(stages, compute: :native)
      [{name, NativeSegment}] = segment_modules(pipeline)
      [left, right] = textured_pair(26)

      ExUnit.CaptureLog.capture_log(fn ->
        Pipeline.submit(pipeline, left, right)

        assert_receive {:EXIT, ^pipeline,
                        {:device_refused, ^name, "no native implementation of no_such_stage"}},
                       5_000
      end)
    end

    test "stops at the pair the device of a segment after the first refuses, saying why" do
      stages = [
        Pass | List.insert_at(Pipeline.default_stages(disparity: [paths: 3]), 3, UnknownKind)
      ]

      {:ok, pipeline} = start(stages, compute: :native)
      [{name, NativeSegment}] = segment_modules(pipeline)
      [left, right] = textured_pair(27)

      ExUnit.CaptureLog.capture_log(fn ->
        Pipeline.submit(pipeline, left, right)

        assert_receive {:EXIT, ^pipeline,
                        {:device_refused, ^name, "no native implementation of no_such_stage"}},
                       5_000
      end)
    end

    @tag :tmp_dir
    test "stops once the Port fails ten pairs in a row", %{tmp_dir: dir} do
      # A stereo_match that echoes each request, which the Matcher reads as a refusal.
      echo = Path.join(dir, "stereo_match")
      File.write!(echo, "#!/bin/sh\nexec cat\n")
      File.chmod!(echo, 0o755)
      restart_matcher(echo)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)

      name =
        :"rectification+sharpness+disparity+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"

      reason = ExUnit.CaptureLog.with_log(fn -> submit_until_stopped(pipeline, 1..12) end)
      assert {{:device_failing, ^name, :bad_request}, _log} = reason
    end

    # Submits a pair each time the pipeline is ready, until it stops; returns why it stopped.
    defp submit_until_stopped(pipeline, seeds) do
      stopped =
        Enum.find_value(seeds, fn seed ->
          [left, right] = textured_pair(seed)
          Pipeline.submit(pipeline, left, right)

          receive do
            :stereo_pipeline_ready -> nil
            {:EXIT, ^pipeline, reason} -> {:stopped, reason}
          after
            5_000 -> flunk("the pipeline neither took a pair nor stopped")
          end
        end)

      case stopped do
        {:stopped, reason} ->
          reason

        nil ->
          assert_receive {:EXIT, ^pipeline, reason}, 5_000
          reason
      end
    end

    @tag :tmp_dir
    test "stops when a native segment after the first does not answer in time", %{tmp_dir: dir} do
      silent_port(dir)
      stages = [Pass | Pipeline.default_stages(disparity: [paths: 3])]
      {:ok, pipeline} = start(stages, compute: :native, device_timeout_ms: 200)

      [left, right] = textured_pair(25)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:EXIT, ^pipeline, {:device_timeout, 200}}, 2_000
    end

    @tag :tmp_dir
    test "a Port that exits fails the pairs at it, and the next pair is taken", %{tmp_dir: dir} do
      silent_port(dir)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      subscribe_to_pairs()
      [[left, right], [next_left, next_right], last] = Enum.map(14..16, &textured_pair/1)

      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 1_000
      Pipeline.submit(pipeline, next_left, next_right)
      refute_receive :stereo_pipeline_ready, 200

      File.touch!(Path.join(dir, "answer"))
      {:os_pid, os_pid} = Port.info(:sys.get_state(Matcher).port, :os_pid)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)])

      assert_receive :stereo_pipeline_ready, 5_000
      refute_received {:"$gen_cast", {:stereo_pair, _pair}}
      assert receive_pair(pipeline, last).left_frame.capture_ns == 16
    end

    test "refuses an unknown way to compute" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start(Pipeline.default_stages(), compute: :gpu)

      assert message =~ ":nx or :native"
    end
  end

  test "keeps settings changed at runtime across a calibration reload" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])
    {:ok, _} = Pipeline.set_options(pipeline, :gain, gain: 4)
    {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)

    assert :ok = Pipeline.reload_calibration(pipeline)
    values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
    assert %{gain: 4} = values.gain
    assert %{p1: 5} = values.disparity
  end
end
