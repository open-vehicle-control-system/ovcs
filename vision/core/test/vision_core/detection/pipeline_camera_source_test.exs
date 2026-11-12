defmodule VisionCore.Detection.PipelineCameraSourceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.Backend.Stub
  alias VisionCore.Detection.Pipeline
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @moduletag :tmp_dir
  @moduletag :capture_log

  @camera_server VisionCore.Camera.GStreamer.name_for("hq")
  @ms 1_000_000
  # The left half of the frame.
  @person {0, 0.9, {0.0, 0.0, 0.5, 1.0}}

  # Saved at twice the frames' size: placed right only once scaled to them.
  defp calibration do
    %CameraCalibration{
      width: 80,
      height: 40,
      distortion_model: "plumb_bob",
      distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0],
      camera_matrix: [100.0, 0.0, 40.0, 0.0, 100.0, 20.0, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [100.0, 0.0, 40.0, 0.0, 0.0, 100.0, 20.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  defp config(dir, files) do
    camera =
      [name: :hq, driver: VisionCore.Camera.GStreamer] ++
        for file <- files do
          case file do
            :calibration ->
              path = Path.join(dir, "hq.yaml")
              File.write!(path, CameraCalibration.to_yaml(calibration(), "hq"))
              {:calibration, path}

            :pose ->
              path = Path.join(dir, "hq_pose.yaml")
              File.write!(path, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0, 0]\n")
              {:pose, path}
          end
        end

    %VisionCore.Config{components: [{:camera, camera}]}
  end

  defp start_pipeline(dir, opts \\ []) do
    {boxes, opts} = Keyword.pop(opts, :boxes, [@person])
    {files, opts} = Keyword.pop(opts, :files, [:calibration, :pose])
    start_supervised!({Stub, boxes: boxes})

    start_supervised!(
      {Pipeline,
       [name: :hq_people, backend: Stub, source: {:camera, :hq}, config: config(dir, files)] ++
         opts}
    )

    :ok = Outputs.subscribe({:detections, Pipeline.HqPeople})
  end

  # Matched at the frames' size, its rectified intrinsics the camera's scaled ones: a plane 2 m away,
  # or with `right_half: :none` its right half without depth, as out of the stereo view.
  defp publish_pair(capture_ms, opts \\ []) do
    {width, height} = {40, 20}
    frame = %Frame{label: "left", width: width, height: height, capture_ns: capture_ms * @ms}
    right_depth = if opts[:right_half] == :none, do: 0, else: 2000

    depth =
      for _y <- 1..height,
          x <- 0..(width - 1),
          into: <<>>,
          do: <<if(x < 20, do: 2000, else: right_depth)::little-16>>

    pair = %Pair{
      left_frame: frame,
      right_frame: %Frame{frame | label: "right"},
      left: Nx.broadcast(Nx.u8(0), {height, width}),
      depth: depth,
      geometry: %{principal_point: {20.0, 10.0}, focal_length_px: 50.0}
    }

    Outputs.publish({:stereo_pair, VisionCore.Stereo.Pipeline}, {:stereo_pair, pair})
  end

  defp publish_frame(capture_ms) do
    frame = %Frame{
      label: "hq",
      frame_id: "hq_optical",
      width: 40,
      height: 20,
      capture_ns: capture_ms * @ms,
      rgb: :binary.copy(<<1, 2, 3>>, 40 * 20)
    }

    Outputs.publish({:camera_frame, @camera_server}, {:camera_frame, frame})
  end

  defp detections(timeout \\ 1_000) do
    assert_receive {:"$gen_cast", {:detections, %Frame{label: "hq"}, detections, :hq_people}},
                   timeout

    detections
  end

  # The box centre, (10, 10), through the scaled camera matrix.
  defp assert_bearing(detection) do
    {azimuth, elevation} = detection.bearing
    assert_in_delta azimuth, :math.atan(-0.2), 1.0e-6
    assert_in_delta elevation, 0.0, 1.0e-6
  end

  defp assert_no_distance(detection) do
    assert %{x: nil, y: nil, z: nil, width: nil, height: nil, depth: nil} = detection
    assert detection.caption == "person 0.90"
  end

  test "places a box with the pair captured with the frame, through the calibration scaled to the frame",
       %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(100)
    publish_frame(100)

    assert [person] = detections()
    assert %{label: "person", score: 0.9, box: %{x0: +0.0, x1: 20.0}} = person
    assert_in_delta person.z, 2.0, 1.0e-6
    assert_in_delta person.x, -0.4, 1.0e-6
    assert_in_delta person.width, 0.8, 1.0e-6
    assert person.depth == 0.1
    assert_bearing(person)
    assert person.outline == [{0.0, 0.0}, {20.0, 0.0}, {20.0, 20.0}, {0.0, 20.0}]
    assert person.caption == "person 0.90 2.00m"
  end

  test "waits for a pair captured after the frame, which may be closer", %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(100)
    publish_frame(140)

    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    publish_pair(150)

    assert [person] = detections()
    assert_in_delta person.z, 2.0, 1.0e-6
  end

  test "skips the frames that come while a frame's boxes wait for their pair", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(100)
    publish_frame(160)

    # The Stub takes every frame where a backend would be busy: frame 190 comes once frame 160's boxes wait.
    _submitted = :sys.get_state(Pipeline.HqPeople)
    _waiting = :sys.get_state(Pipeline.HqPeople)
    publish_frame(190)
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    publish_pair(150)
    publish_pair(200)

    assert_receive {:"$gen_cast",
                    {:detections, %Frame{capture_ns: 160_000_000}, [person], :hq_people}},
                   1_000

    assert_in_delta person.z, 2.0, 1.0e-6
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
  end

  test "keeps a box out of the stereo view without a distance, with its bearing, beside a placed one",
       %{tmp_dir: dir} do
    start_pipeline(dir, boxes: [@person, {2, 0.8, {0.5, 0.0, 1.0, 1.0}}])
    publish_pair(0)
    publish_pair(100, right_half: :none)
    publish_frame(100)

    assert [person, car] = detections()
    assert_in_delta person.z, 2.0, 1.0e-6
    assert %{label: "car", z: nil, x: nil, width: nil} = car
    {azimuth, _elevation} = car.bearing
    assert_in_delta azimuth, :math.atan(0.2), 1.0e-6
  end

  test "keeps a box without a distance, with its bearing, when no pair comes", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 20)
    publish_frame(100)

    assert [person] = detections()
    assert_no_distance(person)
    assert_bearing(person)
  end

  test "keeps a box without a distance when no pair was captured within half a pair period",
       %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(100)
    publish_pair(200)
    publish_frame(360)
    publish_pair(500)

    assert [person] = detections()
    assert_no_distance(person)
  end

  test "a camera without a pose places nothing, saying so once", %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        start_pipeline(dir, files: [:calibration])
        publish_pair(0)
        publish_pair(100)
        publish_frame(100)
        assert [person] = detections()
        assert_no_distance(person)
        assert_bearing(person)

        publish_frame(200)
        publish_pair(200)
        assert [_person] = detections()
      end)

    assert [_once] = Regex.scan(~r/has no pose/, log)
  end

  test "a camera without a calibration gives no bearing either", %{tmp_dir: dir} do
    start_pipeline(dir, files: [:pose], pair_wait_ms: 20)
    publish_frame(100)

    assert [person] = detections()
    assert_no_distance(person)
    assert person.bearing == nil
  end

  test "publishes a frame without boxes at once, without waiting for a pair", %{tmp_dir: dir} do
    start_pipeline(dir, boxes: [], pair_wait_ms: 60_000)
    publish_frame(100)

    assert [] = detections()
  end

  test "detects on every :detect_every_n-th frame", %{tmp_dir: dir} do
    start_pipeline(dir, boxes: [], detect_every_n: 2)
    publish_frame(100)
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    publish_frame(200)

    assert [] = detections()
  end

  test "declares its placement's projection settings, fixed at start" do
    state = %{
      name: :hq_people,
      source: {:camera, :hq},
      detect_every_n: 1,
      min_score: 0.5,
      max_detections: 10,
      depth_sample_fraction: 0.5,
      reprojection_stride: 3,
      pair_wait_ms: 500
    }

    [input, _filtering, placement] = Pipeline.groups(state)

    assert input.summary =~ "camera hq"

    assert Enum.map(placement.parameters, &{&1.name, &1.get.()}) == [
             {"depth_sample_fraction", 0.5},
             {"reprojection_stride", 3},
             {"pair_wait_ms", 500}
           ]
  end

  test "the default pipeline does not take a camera source", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    start_supervised!({Stub, []})

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             Pipeline.start_link(
               backend: Stub,
               source: {:camera, :hq},
               config: config(dir, [:calibration, :pose])
             )

    assert message =~ "needs a :name"
  end

  test "a camera source names a camera of the configuration", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    start_supervised!({Stub, []})

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             Pipeline.start_link(
               name: :hq_people,
               backend: Stub,
               source: {:camera, :usb},
               config: config(dir, [])
             )

    assert message =~ ":usb"
  end
end
