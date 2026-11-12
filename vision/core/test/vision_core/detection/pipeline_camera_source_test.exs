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

  # Tells the test of each frame it is handed, then answers with one person on its left half.
  defmodule Recorder do
    @behaviour VisionCore.Detection.Backend

    def detect(test, sequence, _image) do
      send(test, {:submitted, sequence})
      person = %{class_id: 0, score: 0.9, x0: 0.0, y0: 0.0, x1: 20.0, y1: 20.0}
      send(self(), {:inference_detections, sequence, [person]})
      :ok
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def inference_times(_server), do: nil
  end

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
       [
         name: :hq_people,
         backend: Stub,
         source: {:camera, :hq},
         config: config(dir, files),
         clock: start_clock()
       ] ++ opts}
    )

    :ok = Outputs.subscribe({:detections, Pipeline.HqPeople})
  end

  # The pipeline's clock, at 0 until a test moves it with `set_clock/1`.
  defp start_clock do
    start_supervised!(%{
      id: :clock,
      start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.Clock]]}
    })

    fn -> Agent.get(__MODULE__.Clock, & &1) end
  end

  defp set_clock(ms), do: Agent.update(__MODULE__.Clock, fn _now_ns -> ms * @ms end)

  # Matched at the frames' size, its rectified intrinsics the camera's scaled ones: a plane
  # `:distance_mm` away (2 m), or with `right_half: :none` its right half without depth, as out of
  # the stereo view.
  defp publish_pair(capture_ms, opts \\ []) do
    {width, height} = {40, 20}
    frame = %Frame{label: "left", width: width, height: height, capture_ns: capture_ms * @ms}
    distance_mm = Keyword.get(opts, :distance_mm, 2000)
    right_depth = if opts[:right_half] == :none, do: 0, else: distance_mm

    depth =
      for _y <- 1..height,
          x <- 0..(width - 1),
          into: <<>>,
          do: <<if(x < 20, do: distance_mm, else: right_depth)::little-16>>

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

  # The first call lets the frame's boxes reach the pipeline, the second has them handled.
  defp await_boxes do
    _submitted = :sys.get_state(Pipeline.HqPeople)
    _handled = :sys.get_state(Pipeline.HqPeople)
  end

  test "waits for a pair captured after the frame, which may be closer", %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)

    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    publish_pair(1_500)

    assert [person] = detections()
    assert_in_delta person.z, 2.0, 1.0e-6
  end

  test "detects the frames that come while boxes wait, publishing each in capture order with its own pair",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    await_boxes()
    publish_frame(1_900)
    await_boxes()

    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    publish_pair(1_500, distance_mm: 3000)
    publish_pair(2_000, distance_mm: 4000)

    assert_receive {:"$gen_cast",
                    {:detections, %Frame{capture_ns: 1_400_000_000}, [first], :hq_people}}

    assert_receive {:"$gen_cast",
                    {:detections, %Frame{capture_ns: 1_900_000_000}, [second], :hq_people}}

    assert_in_delta first.z, 3.0, 1.0e-6
    assert_in_delta second.z, 4.0, 1.0e-6
  end

  test "publishes the frame without its pixels", %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(100)
    publish_frame(100)

    assert_receive {:"$gen_cast",
                    {:detections, %Frame{rgb: nil, frame_id: "hq_optical"}, [_person], :hq_people}}
  end

  test "skips the frames that come while 32 frames' boxes wait for their pair", %{tmp_dir: dir} do
    start_supervised!(
      {Pipeline,
       name: :hq_people,
       backend: Recorder,
       backend_server: self(),
       source: {:camera, :hq},
       pair_wait_ms: 60_000,
       config: config(dir, [:calibration, :pose]),
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:detections, Pipeline.HqPeople})
    publish_pair(0)
    publish_pair(1_000)

    for capture_ms <- 1_001..1_033 do
      publish_frame(capture_ms)
      await_boxes()
    end

    for sequence <- 1..32, do: assert_received({:submitted, ^sequence})
    refute_received {:submitted, _next}
    publish_pair(1_100)

    for capture_ms <- 1_001..1_032 do
      capture_ns = capture_ms * @ms

      assert_receive {:"$gen_cast",
                      {:detections, %Frame{capture_ns: ^capture_ns}, [_person], :hq_people}}
    end

    publish_frame(1_100)
    assert_receive {:submitted, 33}
  end

  test "a stray :pair_wait places nothing before the boxes' pair comes", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    await_boxes()

    send(Pipeline.HqPeople, :pair_wait)
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
  end

  test "publishes without a distance once the stereo pairs stop for two pair periods",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(10)
    publish_frame(100)
    await_boxes()

    set_clock(19)
    send(Pipeline.HqPeople, :pair_wait)
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    set_clock(21)
    send(Pipeline.HqPeople, :pair_wait)

    assert [person] = detections()
    assert_no_distance(person)
  end

  test "publishes without a distance once the boxes waited pair_wait_ms", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 500)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_600)
    await_boxes()

    set_clock(499)
    send(Pipeline.HqPeople, :pair_wait)
    refute_receive {:"$gen_cast", {:detections, _frame, _detections, :hq_people}}, 100
    set_clock(500)
    send(Pipeline.HqPeople, :pair_wait)

    assert [person] = detections()
    assert_no_distance(person)
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

  test "keeps a box without a distance, with its bearing, at once while no pair came",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
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

    assert [
             %{
               name: "detect_every_n",
               description: "Images per detection; 1 detects on every image"
             }
           ] =
             input.parameters

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
