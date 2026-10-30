defmodule VisionCore.Stereo.ParametersTest do
  use ExUnit.Case, async: false

  alias VisionCore.Parameters.MemoryStore
  alias VisionCore.Stereo.{AlignmentCorrection, Parameters}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  # A pipeline answering with the stages it is given, and recording the settings it is sent.
  defmodule Pipeline do
    use GenServer
    def start_link(stages), do: GenServer.start_link(__MODULE__, stages, name: __MODULE__)
    def init(stages), do: {:ok, stages}
    def handle_call(:stage_options, _from, stages), do: {:reply, stages, stages}

    def handle_call({:set_options, stage, options}, {pid, _tag}, stages) do
      send(pid, {:set_options, stage, options})

      stages =
        Enum.map(stages, fn
          %{stage: ^stage} = entry -> %{entry | values: Map.merge(entry.values, Map.new(options))}
          entry -> entry
        end)

      {:reply, {:ok, %{}}, stages}
    end
  end

  # A driver whose one set of controls drives both cameras, as V4L2's.
  defmodule Driver do
    use Agent

    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)
    def name_for(label), do: label
    def shared_controls?, do: true
    def control_specs, do: VisionCore.Camera.V4L2.control_specs()
    def controls("left"), do: Agent.get(__MODULE__, & &1.controls)
    def live("left"), do: Agent.get(__MODULE__, & &1.live)

    def set_controls("left", controls) do
      Agent.update(__MODULE__, &%{&1 | controls: Map.merge(&1.controls, Map.new(controls))})
      {:ok, controls("left")}
    end
  end

  # Answers `VisionCore.Status.snapshot/0` with the snapshot it holds.
  defmodule Status do
    use GenServer

    def start_link(snapshot),
      do: GenServer.start_link(__MODULE__, snapshot, name: VisionCore.Status)

    def put(snapshot), do: GenServer.call(VisionCore.Status, {:put, snapshot})
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call({:put, snapshot}, _from, _snapshot), do: {:reply, :ok, snapshot}
  end

  @stages [
    %{
      stage: :rectify,
      summary: "Rectifies",
      specs: [right_row_offset: %{type: :double, range: {-8, 8}, applies: :live}],
      values: %{right_row_offset: 0.0}
    },
    %{stage: :sharpness, summary: "Sharpness", specs: [], values: %{}},
    %{
      stage: :match,
      summary: "Matches",
      specs: [
        p1: %{type: :integer, range: {0, 78}, applies: :live},
        p2: %{type: :integer, range: {1, 79}, greater_than: :p1, applies: :live},
        num_disparities: %{type: :integer, values: [64, 128], applies: :build},
        paths: %{type: :integer, values: [3, 8], applies: :build}
      ],
      values: %{p1: 8, p2: 40, num_disparities: 64, paths: 8}
    },
    %{
      stage: :post_filter,
      summary: "Filters",
      specs: [median: %{type: :bool, applies: :live}],
      values: %{median: true}
    },
    %{stage: :alignment, summary: "Measures", specs: [], values: %{}}
  ]

  @controls Map.new(VisionCore.Camera.V4L2.control_specs(), &{&1.key, &1.default})

  setup do
    start_supervised!({Pipeline, @stages})
    start_supervised!({Driver, %{controls: @controls, live: nil}})
    :ok
  end

  defp groups(opts \\ []) do
    [
      topic_prefix: "stereo",
      driver: Driver,
      pipeline: Pipeline,
      left: [device: "/dev/video0", sync: :server, calibration_path: "/rom/left.yaml"],
      right: [device: "/dev/video1"],
      width: 1280,
      height: 720,
      fps: 30,
      match_width: 640,
      match_height: 360
    ]
    |> Keyword.merge(opts)
    |> Parameters.groups()
  end

  defp group(id), do: Enum.find(groups(), &(&1.id == id))
  defp parameter(group, name), do: Enum.find(group.parameters, &(&1.name == name))

  test "declares the cameras, then one group per stage in pipeline order" do
    groups = groups()

    assert Enum.map(groups, & &1.id) == [
             "stereo.cameras",
             "stereo.rectify",
             "stereo.sharpness",
             "stereo.match",
             "stereo.post_filter",
             "stereo.alignment"
           ]

    assert Enum.map(groups, & &1.position) == [0, 1, 2, 3, 4, 5]
    assert %{name: "Cameras", kind: :component, placement: :flow} = hd(groups)
    assert %{name: "Post filter", kind: :stage, summary: "Filters"} = group("stereo.post_filter")
  end

  test "a driver without shared controls declares no cameras group" do
    refute Enum.any?(groups(driver: VisionCore.Camera.LibCamera), &(&1.id == "stereo.cameras"))
  end

  test "exposure and gain are set by auto exposure, and read what the sensors apply" do
    Agent.update(Driver, &%{&1 | live: %{exposure_time_us: 8000, analogue_gain: 2.5}})
    cameras = group("stereo.cameras")
    exposure = parameter(cameras, "exposure_us")
    gain = parameter(cameras, "analogue_gain")

    assert exposure.applies == {:auto, "stereo.cameras.auto_exposure"}
    assert gain.applies == {:auto, "stereo.cameras.auto_exposure"}
    assert exposure.get.() == 8000
    assert gain.get.() == 2.5
    assert exposure.export == [:components, :stereo, :left, :exposure_us]

    Driver.set_controls("left", auto_exposure: false, exposure_us: 3000)
    assert exposure.get.() == 3000
  end

  test "exposure reads the manual setting while nothing has been reported" do
    cameras = group("stereo.cameras")
    assert parameter(cameras, "exposure_us").get.() == 8000
    assert parameter(cameras, "analogue_gain").get.() == 2.0
  end

  test "a camera setting changed through its parameter reaches the driver" do
    focus = parameter(group("stereo.cameras"), "focus")
    assert %{kind: :range, min: 0, max: 1023} = focus.constraint
    assert :ok = focus.set.(300)
    assert Driver.controls("left").focus == 300
  end

  test "rotation is a choice of 0 and 180" do
    rotation = parameter(group("stereo.cameras"), "rotation")
    assert rotation.constraint == %{kind: :choices, values: [0, 180]}
    assert parameter(group("stereo.cameras"), "auto_exposure").constraint == %{kind: :bool}
  end

  test "build parameters carry the capture and matching sizes" do
    cameras = group("stereo.cameras")
    rectify = group("stereo.rectify")

    for {group, name, value} <- [
          {cameras, "width", 1280},
          {cameras, "height", 720},
          {cameras, "fps", 30},
          {cameras, "left_device", "/dev/video0"},
          {cameras, "left_sync", "server"},
          {cameras, "right_device", "/dev/video1"},
          {rectify, "match_width", 640},
          {rectify, "match_height", 360}
        ] do
      assert %{applies: :build} = parameter = parameter(group, name)
      assert parameter.get.() == value
    end

    refute parameter(cameras, "left_calibration_path")
  end

  test "Match's p2 is declared above p1, its disparities and paths as build parameters" do
    match = group("stereo.match")

    assert %{greater_than: "p1", constraint: %{kind: :range, min: 1, max: 79}} =
             parameter(match, "p2")

    assert %{applies: :build, constraint: %{kind: :choices, values: [64, 128]}} =
             parameter(match, "num_disparities")

    assert %{applies: :build} = paths = parameter(match, "paths")
    assert paths.get.() == 8
    assert parameter(match, "p1").export == [:components, :stereo, :stages, :match, :p1]
    assert parameter(group("stereo.post_filter"), "median").constraint == %{kind: :bool}
  end

  test "a stage setting changed through its parameter reaches the pipeline" do
    p1 = parameter(group("stereo.match"), "p1")
    assert :ok = p1.set.(12)
    assert_received {:set_options, :match, [p1: 12]}
    assert p1.get.() == 12
  end

  test "right_row_offset is set by the alignment correction while it runs, live otherwise" do
    offset = fn -> parameter(group("stereo.rectify"), "right_row_offset") end
    assert offset.().applies == :live

    start_supervised!({AlignmentCorrection, subscribe: false})
    assert offset.().applies == {:auto, "stereo.alignment.correction"}
  end

  test "right_row_offset stays live without an alignment stage to declare the correction" do
    stop_supervised!(Pipeline)
    start_supervised!({Pipeline, Enum.reject(@stages, &(&1.stage == :alignment))})
    start_supervised!({AlignmentCorrection, subscribe: false})

    assert parameter(group("stereo.rectify"), "right_row_offset").applies == :live
    refute group("stereo.alignment")
  end

  test "the alignment group carries the correction switch and the row offset as its status" do
    refute parameter(group("stereo.alignment"), "correction")
    assert group("stereo.alignment").status.() == nil

    start_supervised!({AlignmentCorrection, subscribe: false})
    start_supervised!({Status, %{alignment: %{offset_rows: 0.7, band_offset_rows: []}}})
    alignment = group("stereo.alignment")
    correction = parameter(alignment, "correction")

    assert %{type: :bool, export: [:components, :stereo, :align_correction]} = correction
    assert correction.get.() == true
    assert :ok = correction.set.(false)
    refute AlignmentCorrection.enabled?()
    assert alignment.status.() == {:warning, "rows off by 0.7"}

    Status.put(%{alignment: %{offset_rows: -0.24}})
    assert alignment.status.() == {:ok, "-0.24 rows"}

    Status.put(%{alignment: nil})
    assert alignment.status.() == nil
  end

  test "declares its groups into the registry when it runs" do
    start_supervised!({VisionCore.Parameters, store: MemoryStore})
    start_supervised!({Parameters, topic_prefix: "stereo", driver: Driver, pipeline: Pipeline})

    ids = Enum.map(VisionCore.Parameters.groups(), & &1.id)
    assert "stereo.cameras" in ids
    assert {:ok, %{value: 8}} = VisionCore.Parameters.get("stereo.match.p1")
  end

  test "exposure and gain default to their manual settings while auto exposure runs" do
    Agent.update(Driver, fn state ->
      %{
        controls: %{state.controls | exposure_us: 5000, analogue_gain: 1.0},
        live: %{exposure_time_us: 8000, analogue_gain: 2.0}
      }
    end)

    start_supervised!({VisionCore.Parameters, store: MemoryStore})
    start_supervised!({Parameters, topic_prefix: "stereo", driver: Driver, pipeline: Pipeline})

    assert {:ok, %{value: 8000, default: 5000, state: :automatic}} =
             VisionCore.Parameters.get("stereo.cameras.exposure_us")

    assert {:ok, %{value: 2.0, default: 1.0}} =
             VisionCore.Parameters.get("stereo.cameras.analogue_gain")
  end

  test "starts without a registry" do
    assert {:ok, _pid} =
             start_supervised(
               {Parameters, topic_prefix: "stereo", driver: Driver, pipeline: Pipeline}
             )
  end

  test "a calibration reload forgets the saved right_row_offset" do
    calibration = Path.expand("../../support/calibration", __DIR__)

    pipeline =
      start_supervised!(
        {VisionCore.Stereo.Pipeline,
         name: :parameters_reload,
         left_calibration_path: Path.join(calibration, "identity_left.yaml"),
         right_calibration_path: Path.join(calibration, "identity_right.yaml"),
         width: 64,
         height: 48}
      )

    start_supervised!(
      {MemoryStore, %{"stereo.rectify.right_row_offset" => 1.5, "stereo.match.p1" => 5}}
    )

    start_supervised!({VisionCore.Parameters, store: MemoryStore})

    start_supervised!({Parameters, topic_prefix: "stereo", driver: Driver, pipeline: pipeline})

    assert {:ok, %{value: 1.5}} = VisionCore.Parameters.get("stereo.rectify.right_row_offset")
    assert :ok = StereoSupervisor.reload_calibration(pipeline, "stereo")

    assert MemoryStore.rows() == %{"stereo.match.p1" => 5}

    assert {:ok, %{value: +0.0, state: :builtin}} =
             VisionCore.Parameters.get("stereo.rectify.right_row_offset")
  end
end
