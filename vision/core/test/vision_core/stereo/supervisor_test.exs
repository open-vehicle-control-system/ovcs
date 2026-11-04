defmodule VisionCore.Stereo.SupervisorTest do
  # One test changes the app env the defn options default to.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import VisionCore.Stereo.TestHelpers, only: [calibration_path: 2]

  alias VisionCore.Parameters.MemoryStore
  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pipeline, VehicleRectification}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @moduletag :tmp_dir

  # A camera that runs and captures nothing.
  defmodule IdleCamera do
    use Agent

    def name_for(label), do: Module.concat(__MODULE__, label)

    def start_link(opts),
      do: Agent.start_link(fn -> opts end, name: name_for(Keyword.fetch!(opts, :label)))
  end

  @left_options [calibration_path: "/rom/stereo_left.yaml"]
  @right_options [calibration_path: "/rom/stereo_right.yaml"]

  describe "use_stored_calibration/4" do
    test "leaves the sides alone without a store", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      assert StereoSupervisor.use_stored_calibration(@left_options, @right_options, nil, "stereo") ==
               {@left_options, @right_options}
    end

    test "keeps the shipped calibration while the store is empty", %{tmp_dir: tmp_dir} do
      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
      assert left[:calibration_store_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_store_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end

    test "does not pair one stored side with a shipped one", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
    end

    test "uses the stored calibration once both sides are stored", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end
  end

  describe "pipeline_options/1" do
    @stereo [
      driver: VisionCore.Camera.V4L2,
      left: [calibration_path: "/rom/stereo_left.yaml"],
      right: [calibration_path: "/rom/stereo_right.yaml"]
    ]

    # The defn options of the pipeline's NxSegment.
    defp defn_options(stereo) do
      [{NativeSegment, matcher: Matcher}, {NxSegment, defn_options: defn_options}] =
        StereoSupervisor.pipeline_options(stereo)[:backends]

      defn_options
    end

    test "gives the pipeline native backends on the Matcher, then Nx with the component's defn options" do
      opts =
        StereoSupervisor.pipeline_options(
          @stereo ++ [defn_options: [compiler: Nx.Defn.Evaluator]]
        )

      assert opts[:backends] == [
               {NativeSegment, matcher: Matcher},
               {NxSegment, defn_options: [compiler: Nx.Defn.Evaluator]}
             ]

      refute Keyword.has_key?(opts, :defn_options)
    end

    test "without them, config :vision_core, :nx_defn_options, else EXLA where it is loaded" do
      configured = Application.fetch_env!(:vision_core, :nx_defn_options)
      assert defn_options(@stereo) == configured
      assert defn_options(@stereo ++ [defn_options: nil]) == configured

      Application.delete_env(:vision_core, :nx_defn_options)
      on_exit(fn -> Application.put_env(:vision_core, :nx_defn_options, configured) end)
      assert defn_options(@stereo) == [compiler: EXLA]
    end

    test "gives the pipeline the component's backends, refusing defn options beside them" do
      backends = [{NxSegment, defn_options: [compiler: EXLA]}]
      opts = StereoSupervisor.pipeline_options(@stereo ++ [backends: backends])
      assert opts[:backends] == backends
      refute Keyword.has_key?(opts, :defn_options)

      assert StereoSupervisor.pipeline_options(@stereo ++ [backends: backends, defn_options: nil])[
               :backends
             ] == backends

      assert_raise ArgumentError, ~r/^:defn_options sets the default backends' NxSegment/, fn ->
        StereoSupervisor.pipeline_options(
          @stereo ++ [backends: backends, defn_options: [compiler: EXLA]]
        )
      end
    end

    test "refuses two stages that declare right_row_offset" do
      assert_raise ArgumentError, ~r/both declare right_row_offset/, fn ->
        StereoSupervisor.pipeline_options(
          @stereo ++ [stages: Pipeline.default_stages() ++ [VehicleRectification]]
        )
      end
    end
  end

  describe "camera_options/1" do
    defp stereo_config(options), do: %VisionCore.Config{components: [{:stereo, options}]}

    test "the driver, the prefix, the capture size and rate, and each side's frame id and calibration path" do
      assert StereoSupervisor.camera_options(
               stereo_config(
                 driver: VisionCore.Camera.V4L2,
                 width: 640,
                 height: 360,
                 calibration_dir: "/rom/calibration",
                 left: [device: "/dev/video0", frame_id: "front_left_optical"],
                 right: [device: "/dev/video2", calibration_path: "/rom/right.yaml"]
               )
             ) ==
               {:ok,
                [
                  driver: VisionCore.Camera.V4L2,
                  prefix: "stereo",
                  width: 640,
                  height: 360,
                  fps: 30,
                  left: [
                    calibration_path: "/rom/calibration/stereo_left.yaml",
                    device: "/dev/video0",
                    frame_id: "front_left_optical"
                  ],
                  right: [
                    frame_id: "stereo_right",
                    device: "/dev/video2",
                    calibration_path: "/rom/right.yaml"
                  ]
                ]}
    end

    test "the unit's prefix names its frames and calibration files" do
      assert {:ok, options} =
               StereoSupervisor.camera_options(
                 stereo_config(
                   driver: VisionCore.Camera.V4L2,
                   prefix: "front",
                   calibration_dir: "/rom/calibration",
                   left: [],
                   right: []
                 )
               )

      assert options[:prefix] == "front"
      assert options[:left][:frame_id] == "front_left"
      assert options[:right][:calibration_path] == "/rom/calibration/front_right.yaml"
    end

    test "the stored calibration once both sides are stored", %{tmp_dir: tmp_dir} do
      for side <- ["left", "right"],
          do: File.write!(Path.join(tmp_dir, "stereo_#{side}.yaml"), "")

      {:ok, options} =
        StereoSupervisor.camera_options(
          stereo_config(@stereo ++ [calibration_store_dir: tmp_dir])
        )

      assert options[:left][:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert options[:right][:calibration_store_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end

    test "do not refuse the stages or backends the pipeline refuses" do
      backends = [{NxSegment, defn_options: [compiler: EXLA]}]

      {:ok, options} =
        StereoSupervisor.camera_options(
          stereo_config(
            @stereo ++
              [
                stages: Pipeline.default_stages() ++ [VehicleRectification],
                backends: backends,
                defn_options: [compiler: EXLA]
              ]
          )
        )

      assert options[:left][:calibration_path] == "/rom/stereo_left.yaml"
    end

    test "refuse an option the unit does not take, naming where a moved one went" do
      for {option, reason} <- [
            {[topic_prefix: "front"], ":topic_prefix is now :prefix"},
            {[publish_rectified_image: true], ":publish_rectified_image is the ROS 2 exporter's"},
            {[raw_image_max_hz: 5], ":raw_image_max_hz is the ROS 2 exporter's"},
            {[fsp: 30], "no option :fsp"}
          ] do
        assert {:error, refusal} =
                 StereoSupervisor.camera_options(stereo_config(@stereo ++ option))

        assert refusal =~ reason
      end
    end

    test "take every option the unit documents" do
      assert {:ok, _options} =
               StereoSupervisor.camera_options(
                 stereo_config(
                   @stereo ++
                     [
                       width: 640,
                       height: 360,
                       fps: 15,
                       match_width: 320,
                       match_height: 180,
                       prefix: "front",
                       calibration_dir: "/rom/calibration",
                       calibration_store_dir: "/data/calibration",
                       pair_tolerance_ms: 5,
                       align_correction: false,
                       stages: Pipeline.default_stages(),
                       compute: :native,
                       backends: [NxSegment],
                       defn_options: []
                     ]
                 )
               )
    end

    test "take an option given twice, as a keyword list may hold it" do
      assert {:ok, options} =
               StereoSupervisor.camera_options(stereo_config(@stereo ++ [fps: 15, fps: 30]))

      assert options[:fps] == 15
    end

    test "say why there are none: no stereo component, or one whose cameras cannot be read" do
      assert {:error, "no :stereo component"} =
               StereoSupervisor.camera_options(%VisionCore.Config{})

      for malformed <- [
            [left: :front],
            [right: nil],
            [driver: nil],
            [driver: NotACamera]
          ] do
        assert {:error, reason} =
                 StereoSupervisor.camera_options(stereo_config(Keyword.merge(@stereo, malformed)))

        assert is_binary(reason)
      end
    end
  end

  describe "the stereo unit of a config" do
    defp config(components), do: %VisionCore.Config{components: components}

    test "its cameras, left then right, and its outputs: the pipeline's pairs, then each camera's frames" do
      config = config([{:detector, []}, {:stereo, @stereo}])
      left = VisionCore.Camera.V4L2.name_for("left")
      right = VisionCore.Camera.V4L2.name_for("right")

      assert StereoSupervisor.cameras(config) ==
               [{VisionCore.Camera.V4L2, left}, {VisionCore.Camera.V4L2, right}]

      assert StereoSupervisor.outputs(config) == [
               {:stereo_pair, {:stereo_pair, Pipeline}},
               {{:camera_frame, :left}, {:camera_frame, left}},
               {{:camera_frame, :right}, {:camera_frame, right}}
             ]
    end

    test "none without a stereo component, nor with one whose driver names no camera" do
      for config <- [
            config([{:detector, []}]),
            config([{:stereo, Keyword.put(@stereo, :driver, nil)}]),
            config([{:stereo, Keyword.put(@stereo, :driver, NotACamera)}])
          ] do
        assert StereoSupervisor.cameras(config) == []
        assert StereoSupervisor.outputs(config) == []
      end
    end
  end

  test "is left down, saying why, with an option it does not take" do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert StereoSupervisor.start_link(
                 Keyword.merge(@stereo, driver: NotACamera, topic_prefix: "front")
               ) == :ignore
      end)

    assert log =~ "failed to start, cameras down: its :topic_prefix is now :prefix"
  end

  test "gives each camera driver its side's frame id, and starts no ROS 2 service" do
    {:ok, {_flags, children}} =
      StereoSupervisor.init(
        Keyword.merge(@stereo,
          prefix: "front",
          align_correction: false,
          right: [calibration_path: "/rom/stereo_right.yaml", frame_id: "front_right_optical"]
        )
      )

    driver_options = fn side ->
      %{start: {VisionCore.Camera.V4L2, :start_link, [options]}} =
        Enum.find(children, &(&1.id == {:stereo, :driver, side}))

      options
    end

    assert driver_options.(:left)[:frame_id] == "front_left"
    assert driver_options.(:right)[:frame_id] == "front_right_optical"
    refute Enum.any?(children, &match?(%{id: {:stereo, :set_camera_info, _side}}, &1))
  end

  describe "an uncalibrated unit" do
    defp child_ids(opts) do
      {:ok, {_flags, children}} = StereoSupervisor.init(opts)
      Enum.map(children, & &1.id)
    end

    defp in_dir(tmp_dir),
      do:
        Keyword.merge(@stereo, calibration_dir: tmp_dir, left: [device: "/dev/video0"], right: [])

    defp install_calibration(tmp_dir, sides) do
      for side <- sides,
          do:
            File.cp!(calibration_path(:identity, side), Path.join(tmp_dir, "stereo_#{side}.yaml"))
    end

    defp start_unit(tmp_dir) do
      Process.flag(:trap_exit, true)
      StereoSupervisor.start_link(Keyword.put(in_dir(tmp_dir), :driver, IdleCamera))
    end

    test "with neither calibration file, starts the two cameras alone and says so",
         %{tmp_dir: tmp_dir} do
      log =
        capture_log(fn ->
          assert {:ok, unit} = start_unit(tmp_dir)

          assert unit |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
                   [{:stereo, :driver, :left}, {:stereo, :driver, :right}]

          Supervisor.stop(unit)
        end)

      assert log =~ "uncalibrated"
      assert log =~ Path.join(tmp_dir, "stereo_left.yaml")
    end

    test "without calibration paths, starts the two cameras alone" do
      log =
        capture_log(fn ->
          assert child_ids(Keyword.merge(@stereo, left: [], right: [])) == [
                   {:stereo, :driver, :left},
                   {:stereo, :driver, :right}
                 ]
        end)

      assert log =~ "uncalibrated"
    end

    test "with one calibration file, fails to start, the pipeline refusing the missing one",
         %{tmp_dir: tmp_dir} do
      install_calibration(tmp_dir, [:left])

      log = capture_log(fn -> assert start_unit(tmp_dir) == :ignore end)

      assert log =~ "failed to start, cameras down"
      assert log =~ "cannot read calibration"
      assert log =~ Path.join(tmp_dir, "stereo_right.yaml")
      assert Process.whereis(StereoSupervisor) == nil
    end

    test "with both calibration files, starts the pipeline", %{tmp_dir: tmp_dir} do
      install_calibration(tmp_dir, [:left, :right])
      assert Pipeline in child_ids(in_dir(tmp_dir))
    end

    test "calibrated?/1 once both sides' calibration files exist", %{tmp_dir: tmp_dir} do
      config = %VisionCore.Config{components: [{:stereo, in_dir(tmp_dir)}]}
      refute StereoSupervisor.calibrated?(config)

      install_calibration(tmp_dir, [:left])
      refute StereoSupervisor.calibrated?(config)

      install_calibration(tmp_dir, [:right])
      assert StereoSupervisor.calibrated?(config)
    end

    test "calibrated?/1 is false without a stereo component" do
      refute StereoSupervisor.calibrated?(%VisionCore.Config{})
    end

    test "a commit forgets the saved row offset before it restarts the unit", %{tmp_dir: tmp_dir} do
      start_supervised!(
        {MemoryStore,
         %{"stereo.rectification.right_row_offset" => 2.0, "stereo.disparity.p1" => 5}}
      )

      start_supervised!({VisionCore.Parameters, store: MemoryStore})
      config = %VisionCore.Config{components: [{:stereo, in_dir(tmp_dir)}]}
      test = self()

      calibrations =
        Map.new([:left, :right], fn side ->
          {side, VisionCore.Ros2.CameraCalibration.load!(calibration_path(:identity, side))}
        end)

      assert :ok =
               VisionCore.Stereo.Calibration.commit(config, calibrations,
                 pipeline_running?: fn -> false end,
                 restart: fn ->
                   send(test, {:restarted, MemoryStore.rows()})
                   {:ok, test}
                 end
               )

      assert_received {:restarted, %{"stereo.disparity.p1" => 5} = rows}
      assert map_size(rows) == 1
    end

    test "forget_row_offset/1 forgets the offset of the stage that declares it, whatever its name" do
      start_supervised!(
        {MemoryStore,
         %{
           "front.vehicle_rectification.right_row_offset" => 2.0,
           "front.disparity.p1" => 5
         }}
      )

      start_supervised!({VisionCore.Parameters, store: MemoryStore})

      stereo =
        Keyword.merge(@stereo,
          prefix: "front",
          stages: [VehicleRectification | tl(Pipeline.default_stages())]
        )

      assert :ok =
               StereoSupervisor.forget_row_offset(%VisionCore.Config{
                 components: [stereo: stereo]
               })

      assert MemoryStore.rows() == %{"front.disparity.p1" => 5}
      assert :ok = StereoSupervisor.forget_row_offset(%VisionCore.Config{})
    end

    test "pipeline_options/1 still names the calibration it needs", %{tmp_dir: tmp_dir} do
      opts = StereoSupervisor.pipeline_options(in_dir(tmp_dir))
      assert opts[:left_calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
    end
  end

  describe "reload_calibration/3" do
    defp start_pipeline(stages) do
      start_supervised!(
        {Pipeline,
         name: :reload_row_offset,
         stages: stages,
         left_calibration_path: calibration_path(:identity, :left),
         right_calibration_path: calibration_path(:identity, :right),
         width: 64,
         height: 48,
         defn_options: [compiler: EXLA]}
      )
    end

    test "starts the row correction over from the new calibration" do
      pipeline = start_pipeline(Pipeline.default_stages())

      {:ok, _} = Pipeline.set_options(pipeline, :rectification, right_row_offset: 2.0)
      {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)
      assert :ok = StereoSupervisor.reload_calibration(pipeline, "stereo")

      values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
      assert values.rectification.right_row_offset == 0.0
      assert values.disparity.p1 == 5
    end

    test "resets the stage that declares right_row_offset, whatever its name, and forgets its saved value" do
      start_supervised!(
        {MemoryStore,
         %{"stereo.vehicle_rectification.right_row_offset" => 2.0, "stereo.disparity.p1" => 5}}
      )

      start_supervised!({VisionCore.Parameters, store: MemoryStore})
      pipeline = start_pipeline([VehicleRectification | tl(Pipeline.default_stages())])

      {:ok, _} = Pipeline.set_options(pipeline, :vehicle_rectification, right_row_offset: 2.0)
      assert :ok = StereoSupervisor.reload_calibration(pipeline, "stereo")

      values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
      assert values.vehicle_rectification.right_row_offset == 0.0
      assert MemoryStore.rows() == %{"stereo.disparity.p1" => 5}
    end
  end
end
