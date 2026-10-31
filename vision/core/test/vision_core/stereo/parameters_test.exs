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

  # A driver with controls per camera, as LibCamera's, recording what it is sent.
  defmodule SideDriver do
    use Agent

    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)
    def name_for(label), do: label
    def control_specs, do: VisionCore.Camera.LibCamera.control_specs()
    def controls(label), do: Agent.get(__MODULE__, & &1.controls[label])
    def live(label), do: Agent.get(__MODULE__, & &1.live[label])
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def set_controls(label, controls) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | calls: [{label, controls} | state.calls],
            controls: Map.update!(state.controls, label, &Map.merge(&1, Map.new(controls)))
        }
      end)

      {:ok, controls(label)}
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
      stage: :rectification,
      summary: "Rectifies",
      specs: [right_row_offset: %{type: :double, range: {-8, 8}, applies: :live}],
      values: %{right_row_offset: 0.0}
    },
    %{stage: :sharpness, summary: "Sharpness", specs: [], values: %{}},
    %{
      stage: :disparity,
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
      stage: :median_filter,
      summary: "Filters",
      specs: [median: %{type: :bool, applies: :live}],
      values: %{median: true}
    },
    %{stage: :row_alignment, summary: "Measures", specs: [], values: %{}}
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
             "stereo.rectification",
             "stereo.sharpness",
             "stereo.disparity",
             "stereo.median_filter",
             "stereo.row_alignment"
           ]

    assert Enum.map(groups, & &1.position) == [0, 1, 2, 3, 4, 5]
    assert %{name: "Cameras", kind: :component, placement: :flow} = hd(groups)

    assert %{name: "Median filter", kind: :stage, summary: "Filters"} =
             group("stereo.median_filter")
  end

  describe "the LibCamera driver" do
    @describetag :tmp_dir

    test "declares the composer's camera settings as defaults before the first frame",
         %{tmp_dir: tmp_dir} do
      executable = Path.join(tmp_dir, "camera_capture")
      File.write!(executable, "#!/bin/sh\nexec cat > /dev/null\n")
      File.chmod!(executable, 0o755)
      left = [brightness: 0.2, exposure_time_us: 6000]

      for {side, opts} <- [left: left, right: []] do
        label = Atom.to_string(side)

        start_supervised!(
          {VisionCore.Camera.LibCamera,
           [label: label, camera_id: 0, executable: executable] ++ opts},
          id: side
        )
      end

      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      start_supervised!(
        {Parameters,
         topic_prefix: "stereo",
         driver: VisionCore.Camera.LibCamera,
         pipeline: Pipeline,
         left: left,
         right: []}
      )

      assert {:ok, %{value: 0.2, default: 0.2, state: :builtin}} =
               VisionCore.Parameters.get("stereo.cameras.brightness")

      assert {:ok, %{value: false, default: false}} =
               VisionCore.Parameters.get("stereo.cameras.auto_exposure")

      assert {:ok, %{value: 6000, default: 6000}} =
               VisionCore.Parameters.get("stereo.cameras.exposure_time_us")
    end
  end

  describe "a driver with controls per camera" do
    @side_controls %{
      exposure_mode: "normal",
      exposure_time_us: 0,
      analogue_gain: 0.0,
      lens_position: nil,
      brightness: 0.0,
      contrast: 1.0,
      sharpness: 1.0,
      noise_reduction: "auto"
    }

    setup do
      start_supervised!(
        {SideDriver,
         %{
           controls: %{"left" => @side_controls, "right" => @side_controls},
           live: %{
             "left" => %{exposure_time_us: 8000, analogue_gain: 2.5},
             "right" => %{exposure_time_us: 9000, analogue_gain: 3.0}
           },
           calls: []
         }}
      )

      :ok
    end

    defp cameras_group(opts \\ []) do
      [driver: SideDriver]
      |> Keyword.merge(opts)
      |> groups()
      |> Enum.find(&(&1.id == "stereo.cameras"))
    end

    test "gets one Cameras group, whose settings go to both cameras and to both sides of the composer" do
      groups = groups(driver: SideDriver)
      ids = Enum.map(groups, & &1.id)

      assert hd(ids) == "stereo.cameras"
      refute "stereo.left_camera" in ids
      refute "stereo.right_camera" in ids

      assert %{name: "Cameras", kind: :component, placement: :flow, position: 0} = hd(groups)

      lens = parameter(hd(groups), "lens_position")

      assert lens.export == [
               [:components, :stereo, :left, :lens_position],
               [:components, :stereo, :right, :lens_position]
             ]

      assert :ok = lens.set.(1.0)

      assert SideDriver.calls() == [
               {"left", [lens_position: 1.0]},
               {"right", [lens_position: 1.0]}
             ]

      refute Map.has_key?(parameter(hd(groups), "auto_exposure"), :export)
    end

    test "auto exposure is on while the exposure is 0, and switching it on sets 0 on both cameras" do
      cameras = cameras_group()
      auto = parameter(cameras, "auto_exposure")
      exposure = parameter(cameras, "exposure_time_us")

      assert auto.get.() == true
      assert exposure.applies == {:auto, "stereo.cameras.auto_exposure"}
      assert exposure.constraint == %{kind: :range, min: 1, max: 1_000_000, step: nil}
      assert exposure.get.() == 8000

      assert :ok = exposure.set.(5000)
      assert auto.get.() == false
      assert exposure.get.() == 5000

      assert :ok = auto.set.(true)

      assert SideDriver.calls() == [
               {"left", [exposure_time_us: 5000]},
               {"right", [exposure_time_us: 5000]},
               {"left", [exposure_time_us: 0]},
               {"right", [exposure_time_us: 0]}
             ]

      assert auto.get.() == true
    end

    test "gain follows its own switch and range" do
      cameras = cameras_group()
      gain = parameter(cameras, "analogue_gain")

      assert gain.applies == {:auto, "stereo.cameras.auto_gain"}
      assert gain.constraint == %{kind: :range, min: 1, max: 16, step: nil}
      assert gain.get.() == 2.5
      assert parameter(cameras, "auto_gain").get.() == true
      assert :ok = parameter(cameras, "auto_gain").set.(false)
      assert SideDriver.calls() == []
    end

    test "an automatic value falls back to the manual minimum before the left camera reports" do
      Agent.update(
        SideDriver,
        &%{&1 | live: %{"left" => nil, "right" => %{exposure_time_us: 9000}}}
      )

      assert parameter(cameras_group(), "exposure_time_us").get.() == 1
    end

    test "exposure and gain default to the composer's manual values for the left camera" do
      cameras = cameras_group(left: [exposure_time_us: 6000, analogue_gain: 1.5])

      assert %{default: 6000} = parameter(cameras, "exposure_time_us")
      assert %{default: 1.5} = parameter(cameras, "analogue_gain")
      refute Map.has_key?(parameter(cameras_group(), "exposure_time_us"), :default)
    end

    test "carries the capture size and each camera's addressing as build parameters" do
      cameras =
        cameras_group(
          left: [
            camera_id: 1,
            sync: :server,
            sensor_mode: {2028, 1080, 12},
            format: :grey,
            label: "x"
          ],
          right: [camera_id: 0, sync: :client]
        )

      for {name, value} <- [
            {"width", 1280},
            {"height", 720},
            {"fps", 30},
            {"left_camera_id", 1},
            {"left_sync", "server"},
            {"left_sensor_mode", "2028x1080:12"},
            {"left_format", "grey"},
            {"right_camera_id", 0},
            {"right_sync", "client"}
          ] do
        assert %{applies: :build} = parameter = parameter(cameras, name)
        assert parameter.get.() == value
      end

      refute parameter(cameras, "left_label")
    end

    test "switching off before the camera reports sets the manual value on both cameras, never 0" do
      Agent.update(SideDriver, &%{&1 | live: %{"left" => nil, "right" => nil}})
      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      start_supervised!(
        {Parameters,
         topic_prefix: "stereo",
         driver: SideDriver,
         pipeline: Pipeline,
         left: [exposure_time_us: 6000],
         right: []}
      )

      assert {:ok, %{value: false}} =
               VisionCore.Parameters.set("stereo.cameras.auto_exposure", false)

      assert SideDriver.calls() == [
               {"left", [exposure_time_us: 6000]},
               {"right", [exposure_time_us: 6000]}
             ]
    end

    test "a saved manual exposure over an automatic composer is applied to both and kept on save" do
      start_supervised!(
        {MemoryStore,
         %{
           "stereo.cameras.auto_exposure" => false,
           "stereo.cameras.exposure_time_us" => 20_000
         }}
      )

      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      start_supervised!(
        {Parameters, topic_prefix: "stereo", driver: SideDriver, pipeline: Pipeline}
      )

      assert {:ok, %{value: false, state: :saved}} =
               VisionCore.Parameters.get("stereo.cameras.auto_exposure")

      assert SideDriver.controls("left").exposure_time_us == 20_000
      assert SideDriver.controls("right").exposure_time_us == 20_000

      assert {:ok, %{value: 20_000, state: :saved}} =
               VisionCore.Parameters.get("stereo.cameras.exposure_time_us")

      assert VisionCore.Parameters.save() == {:ok, []}

      assert MemoryStore.rows() == %{
               "stereo.cameras.auto_exposure" => false,
               "stereo.cameras.exposure_time_us" => 20_000
             }
    end

    test "switching auto exposure off gives both cameras the exposure the left one applied" do
      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      start_supervised!(
        {Parameters, topic_prefix: "stereo", driver: SideDriver, pipeline: Pipeline}
      )

      assert {:ok, %{value: true, state: :builtin}} =
               VisionCore.Parameters.get("stereo.cameras.auto_exposure")

      assert {:ok, %{value: false}} =
               VisionCore.Parameters.set("stereo.cameras.auto_exposure", false)

      assert SideDriver.calls() == [
               {"left", [exposure_time_us: 8000]},
               {"right", [exposure_time_us: 8000]}
             ]

      assert {:ok, %{value: 8000, state: :builtin}} =
               VisionCore.Parameters.get("stereo.cameras.exposure_time_us")
    end

    test "a saved value is exported to both cameras' options" do
      start_supervised!({MemoryStore, %{"stereo.cameras.brightness" => 0.3}})
      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      start_supervised!(
        {Parameters, topic_prefix: "stereo", driver: SideDriver, pipeline: Pipeline}
      )

      export = VisionCore.Parameters.export()
      assert export =~ ~r/left: \[[^\]]*brightness: 0\.3/
      assert export =~ ~r/right: \[[^\]]*brightness: 0\.3/
    end
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
    rectification = group("stereo.rectification")

    for {group, name, value} <- [
          {cameras, "width", 1280},
          {cameras, "height", 720},
          {cameras, "fps", 30},
          {cameras, "left_device", "/dev/video0"},
          {cameras, "left_sync", "server"},
          {cameras, "right_device", "/dev/video1"},
          {rectification, "match_width", 640},
          {rectification, "match_height", 360}
        ] do
      assert %{applies: :build} = parameter = parameter(group, name)
      assert parameter.get.() == value
    end

    refute parameter(cameras, "left_calibration_path")
  end

  test "Disparity's p2 is declared above p1, its disparities and paths as build parameters" do
    disparity = group("stereo.disparity")

    assert %{greater_than: "p1", constraint: %{kind: :range, min: 1, max: 79}} =
             parameter(disparity, "p2")

    assert %{applies: :build, constraint: %{kind: :choices, values: [64, 128]}} =
             parameter(disparity, "num_disparities")

    assert %{applies: :build} = paths = parameter(disparity, "paths")
    assert paths.get.() == 8
    assert parameter(disparity, "p1").export == [:components, :stereo, :stages, :disparity, :p1]
    assert parameter(group("stereo.median_filter"), "median").constraint == %{kind: :bool}
  end

  test "a stage setting changed through its parameter reaches the pipeline" do
    p1 = parameter(group("stereo.disparity"), "p1")
    assert :ok = p1.set.(12)
    assert_received {:set_options, :disparity, [p1: 12]}
    assert p1.get.() == 12
  end

  test "right_row_offset is set by the alignment correction while it runs, live otherwise" do
    offset = fn -> parameter(group("stereo.rectification"), "right_row_offset") end
    assert offset.().applies == :live

    start_supervised!({AlignmentCorrection, subscribe: false})
    assert offset.().applies == {:auto, "stereo.row_alignment.correction"}
  end

  test "right_row_offset stays live without a row alignment stage to declare the correction" do
    stop_supervised!(Pipeline)
    start_supervised!({Pipeline, Enum.reject(@stages, &(&1.stage == :row_alignment))})
    start_supervised!({AlignmentCorrection, subscribe: false})

    assert parameter(group("stereo.rectification"), "right_row_offset").applies == :live
    refute group("stereo.row_alignment")
  end

  test "the row alignment group carries the correction switch and the row offset as its status" do
    refute parameter(group("stereo.row_alignment"), "correction")
    assert group("stereo.row_alignment").status.() == nil

    start_supervised!({AlignmentCorrection, subscribe: false})
    start_supervised!({Status, %{alignment: %{offset_rows: 0.7, band_offset_rows: []}}})
    alignment = group("stereo.row_alignment")
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
    assert {:ok, %{value: 8}} = VisionCore.Parameters.get("stereo.disparity.p1")
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

  test "a stage setting without a type constraint, values or range takes any value of its type" do
    stop_supervised!(Pipeline)

    start_supervised!(
      {Pipeline,
       [
         %{
           stage: :blur,
           summary: "Blurs",
           specs: [radius: %{type: :integer}],
           values: %{radius: 2}
         }
       ]}
    )

    start_supervised!({VisionCore.Parameters, store: MemoryStore})
    start_supervised!({Parameters, topic_prefix: "stereo", driver: Driver, pipeline: Pipeline})

    assert {:ok, %{constraint: nil}} = VisionCore.Parameters.get("stereo.blur.radius")
    assert {:ok, %{value: 1_000}} = VisionCore.Parameters.set("stereo.blur.radius", 1_000)
    assert {:error, _reason} = VisionCore.Parameters.set("stereo.blur.radius", 1.5)
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
      {MemoryStore, %{"stereo.rectification.right_row_offset" => 1.5, "stereo.disparity.p1" => 5}}
    )

    start_supervised!({VisionCore.Parameters, store: MemoryStore})

    start_supervised!({Parameters, topic_prefix: "stereo", driver: Driver, pipeline: pipeline})

    assert {:ok, %{value: 1.5}} =
             VisionCore.Parameters.get("stereo.rectification.right_row_offset")

    assert :ok = StereoSupervisor.reload_calibration(pipeline, "stereo")

    assert MemoryStore.rows() == %{"stereo.disparity.p1" => 5}

    assert {:ok, %{value: +0.0, state: :builtin}} =
             VisionCore.Parameters.get("stereo.rectification.right_row_offset")
  end

  test "a sensor mode with its bit depth reads as one string" do
    assert %{type: :string, get: get} =
             VisionCore.Stereo.Parameters.build_parameter({:sensor_mode, {2028, 1520, 12}})

    assert get.() == "2028x1520:12"
  end
end
