defmodule VisionCore.Stereo.SupervisorTest do
  # One test changes the app env the defn options default to.
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers, only: [calibration_path: 2]

  alias VisionCore.Parameters.MemoryStore
  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pipeline, VehicleRectification}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @moduletag :tmp_dir

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
    test "the driver, the capture size and rate, and each side's frame id and calibration path" do
      assert StereoSupervisor.camera_options(
               driver: VisionCore.Camera.V4L2,
               width: 640,
               height: 360,
               calibration_dir: "/rom/calibration",
               left: [device: "/dev/video0", frame_id: "front_left_optical"],
               right: [device: "/dev/video2", calibration_path: "/rom/right.yaml"]
             ) == [
               driver: VisionCore.Camera.V4L2,
               topic_prefix: "stereo",
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
             ]
    end

    test "the stored calibration once both sides are stored", %{tmp_dir: tmp_dir} do
      for side <- ["left", "right"],
          do: File.write!(Path.join(tmp_dir, "stereo_#{side}.yaml"), "")

      options = StereoSupervisor.camera_options(@stereo ++ [calibration_store_dir: tmp_dir])

      assert options[:left][:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert options[:right][:calibration_store_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end

    test "do not refuse the stages or backends the pipeline refuses" do
      backends = [{NxSegment, defn_options: [compiler: EXLA]}]

      options =
        StereoSupervisor.camera_options(
          @stereo ++
            [
              stages: Pipeline.default_stages() ++ [VehicleRectification],
              backends: backends,
              defn_options: [compiler: EXLA]
            ]
        )

      assert options[:left][:calibration_path] == "/rom/stereo_left.yaml"
    end
  end

  describe "the stereo unit of a config" do
    defp config(components),
      do: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: components}

    test "its cameras, left then right, and its outputs: the pipeline's pairs, then each camera's frames" do
      config = config([:heartbeat, {:stereo, @stereo}])
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

    test "none without a stereo component" do
      assert StereoSupervisor.cameras(config([:heartbeat])) == []
      assert StereoSupervisor.outputs(config([:heartbeat])) == []
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

    test "has the ROS 2 exporter read its camera info from the new calibration" do
      pipeline = start_pipeline(Pipeline.default_stages())
      test = self()
      driver = VisionCore.Camera.V4L2

      start_supervised!(
        {VisionCore.Exporter.Runner,
         exporter: VisionCore.Ros2.Exporter,
         options: [
           name: VisionCore.Ros2.Exporter,
           stereo: [
             driver: driver,
             width: 64,
             height: 48,
             camera_info_interval_frames: 1,
             left: [calibration_path: calibration_path(:identity, :left)],
             right: [calibration_path: calibration_path(:identity, :right)]
           ],
           publish: fn topic, _module, message, _options -> send(test, {topic, message}) end
         ],
         config: %VisionCore.Config{
           zenoh_endpoint_ip: "127.0.0.1",
           components: [{:stereo, @stereo}]
         }}
      )

      camera_info = fn ->
        :sys.get_state(VisionCore.Ros2.Exporter)

        frame = %VisionCore.Camera.Frame{
          label: "left",
          width: 64,
          height: 48,
          capture_ns: 0,
          jpeg: <<>>
        }

        VisionCore.Outputs.publish(
          {:camera_frame, driver.name_for("left")},
          {:camera_frame, frame}
        )

        assert_receive {"stereo/left/camera_info", camera_info}, 1_000
        camera_info
      end

      before = camera_info.()

      assert :ok =
               StereoSupervisor.reload_calibration(pipeline, "stereo",
                 left_calibration_path: calibration_path(:distorted, :left),
                 right_calibration_path: calibration_path(:distorted, :right)
               )

      refute camera_info.().d == before.d
    end
  end

  describe "reload_stored_calibration/4" do
    test "waits for the second side before reloading", %{tmp_dir: tmp_dir} do
      left_path = Path.join(tmp_dir, "stereo_left.yaml")
      File.write!(left_path, "")

      assert StereoSupervisor.reload_stored_calibration(
               :no_backend,
               "stereo",
               left_path,
               Path.join(tmp_dir, "stereo_right.yaml")
             ) == :ok
    end
  end
end
