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
    def options, do: []
    def inference_times(_server), do: nil
  end

  # Tells the test of each frame it is handed, answers what the test scripted, `:ok` once the
  # script is spent, and leaves the reply to the test.
  defmodule Held do
    @behaviour VisionCore.Detection.Backend

    def detect({test, script}, sequence, _image) do
      send(test, {:submitted, sequence})

      Agent.get_and_update(script, fn
        [answer | rest] -> {answer, rest}
        [] -> {:ok, []}
      end)
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def options, do: []
    def inference_times(_server), do: nil
  end

  # Fails the first frame, as a backend whose Port went down, and finds a person in the next.
  defmodule FirstFrameLost do
    @behaviour VisionCore.Detection.Backend

    def detect(_server, sequence, _image) do
      person = %{class_id: 0, score: 0.9, x0: 0.0, y0: 0.0, x1: 20.0, y1: 20.0}
      send(self(), {:inference_detections, sequence, if(sequence == 1, do: nil, else: [person])})
      :ok
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def options, do: []
    def inference_times(_server), do: nil
  end

  # Saved at twice the frames' size: placed right only once scaled to them.
  defp calibration do
    %CameraCalibration{
      width: 80,
      height: 40,
      distortion_model: "plumb_bob",
      distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0],
      camera_matrix: [100.0, 0.0, 40.5, 0.0, 100.0, 20.5, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [100.0, 0.0, 40.5, 0.0, 0.0, 100.0, 20.5, 0.0, 0.0, 0.0, 1.0, 0.0]
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
    {config, opts} = Keyword.pop_lazy(opts, :config, fn -> config(dir, files) end)
    {source, opts} = Keyword.pop(opts, :source, {:camera, :hq})
    start_supervised!({Stub, boxes: boxes})

    start_supervised!(
      {Pipeline,
       [
         name: :hq_people,
         backend: Stub,
         source: source,
         config: config,
         clock: start_clock()
       ] ++ opts}
    )

    :ok = Outputs.subscribe({:detections, :hq_people})
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

  defp publish_frame(capture_ms, size \\ {40, 20}, key \\ {:camera_frame, @camera_server})

  defp publish_frame(capture_ms, {width, height}, key) do
    frame = %Frame{
      label: "hq",
      frame_id: "hq_optical",
      width: width,
      height: height,
      capture_ns: capture_ms * @ms,
      rgb: :binary.copy(<<1, 2, 3>>, width * height)
    }

    Outputs.publish(key, {:camera_frame, frame})
  end

  defp detections(timeout \\ 1_000) do
    assert_receive {:"$gen_cast", {{:detections, :hq_people}, {%Frame{label: "hq"}, detections}}},
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

  # The calibration's size made on the CPU, and half of it averaged from it.
  defp outputs_config(dir) do
    calibration = Path.join(dir, "hq.yaml")
    File.write!(calibration, CameraCalibration.to_yaml(calibration(), "hq"))
    pose = Path.join(dir, "hq_pose.yaml")
    File.write!(pose, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0, 0]\n")

    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      sensor_width: 80,
      sensor_height: 40,
      outputs: [
        view: [resolution: {80, 40}, processor: :cpu],
        inference: [resolution: {40, 20}, from: :view]
      ],
      calibration: calibration,
      pose: pose
    ]

    %VisionCore.Config{components: [{:camera, camera}]}
  end

  test "on a camera's output, takes that output's frames and places its boxes at its size",
       %{tmp_dir: dir} do
    start_pipeline(dir, config: outputs_config(dir), source: {:camera, :hq, :inference})
    server = VisionCore.Camera.V4L2Single.name_for("hq")
    publish_pair(0)
    publish_pair(100)
    publish_frame(100, {80, 40}, {:camera_frame, server, :view})
    publish_frame(100, {40, 20}, {:camera_frame, server, :inference})

    assert [person] = detections()
    assert_in_delta person.z, 2.0, 1.0e-6
    assert_in_delta person.x, -0.4, 1.0e-6
    assert_in_delta person.width, 0.8, 1.0e-6
    assert_bearing(person)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
  end

  test "on a camera whose outputs cannot be made, refuses to start saying why" do
    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      outputs: [view: [resolution: {640, 480}, processor: :cpu]]
    ]

    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {Pipeline,
                name: :hq_people,
                backend: Stub,
                source: {:camera, :hq},
                config: %VisionCore.Config{components: [{:camera, camera}]}}
             )

    assert message ==
             "its source names the camera :hq, whose outputs cannot be made: output view: " <>
               "its processor :cpu cannot make 640x480; it makes 2028x1520 or 1014x760"
  end

  test "refuses an output its camera does not have", %{tmp_dir: dir} do
    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {Pipeline,
                name: :hq_people,
                backend: Stub,
                source: {:camera, :hq, :preview},
                config: outputs_config(dir)}
             )

    assert message =~ "the output :preview of the camera :hq, whose outputs are :view, :inference"
  end

  test "refuses an output its camera does not send", %{tmp_dir: dir} do
    config =
      update_in(outputs_config(dir).components, fn [{:camera, camera}] ->
        [
          {:camera,
           put_in(camera[:outputs][:view], Keyword.put(camera[:outputs][:view], :send, false))}
        ]
      end)

    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {Pipeline,
                name: :hq_people, backend: Stub, source: {:camera, :hq, :view}, config: config}
             )

    assert message ==
             "its source names the output :view of the camera :hq, which it does not send " <>
               "(send: false)"
  end

  test "refuses an H.264 output of its camera, a video", %{tmp_dir: dir} do
    config =
      update_in(outputs_config(dir).components, fn [{:camera, camera}] ->
        video = [from: :view, format: :h264, bitrate_kbps: 1_000, keyframe_interval: 30]
        [{:camera, update_in(camera[:outputs], &(&1 ++ [view_h264: video]))}]
      end)

    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {Pipeline,
                name: :hq_people,
                backend: Stub,
                source: {:camera, :hq, :view_h264},
                config: config}
             )

    assert message ==
             "its source names the output :view_h264 of the camera :hq, an H.264 video, " <>
               "not an image"
  end

  # The first call lets the frame's boxes reach the pipeline, the second has them handled.
  defp await_boxes do
    _submitted = :sys.get_state(VisionCore.Pipelines.server(Pipeline, :hq_people))
    _handled = :sys.get_state(VisionCore.Pipelines.server(Pipeline, :hq_people))
  end

  test "waits for a pair captured after the frame, which may be closer", %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)

    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
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

    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
    publish_pair(1_500, distance_mm: 3000)
    publish_pair(2_000, distance_mm: 4000)

    assert_receive {:"$gen_cast",
                    {{:detections, :hq_people}, {%Frame{capture_ns: 1_400_000_000}, [first]}}}

    assert_receive {:"$gen_cast",
                    {{:detections, :hq_people}, {%Frame{capture_ns: 1_900_000_000}, [second]}}}

    assert_in_delta first.z, 3.0, 1.0e-6
    assert_in_delta second.z, 4.0, 1.0e-6
  end

  test "publishes the frame without its pixels", %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_pair(0)
    publish_pair(100)
    publish_frame(100)

    assert_receive {:"$gen_cast",
                    {{:detections, :hq_people},
                     {%Frame{rgb: nil, frame_id: "hq_optical"}, [_person]}}}
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

    :ok = Outputs.subscribe({:detections, :hq_people})
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
                      {{:detections, :hq_people}, {%Frame{capture_ns: ^capture_ns}, [_person]}}}
    end

    publish_frame(1_100)
    assert_receive {:submitted, 33}
  end

  test "places boxes with their pair when it waits in the mailbox behind them, the pipeline running late",
       %{tmp_dir: dir} do
    start_supervised!(
      {Pipeline,
       name: :hq_people,
       backend: Held,
       backend_server: {self(), start_supervised!({Agent, fn -> [] end})},
       source: {:camera, :hq},
       pair_wait_ms: 60_000,
       config: config(dir, [:calibration, :pose]),
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:detections, :hq_people})
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    assert_receive {:submitted, 1}

    # Past the stall the pairs' period would give, with the frame's pair already sent.
    :sys.suspend(VisionCore.Pipelines.server(Pipeline, :hq_people))
    person = %{class_id: 0, score: 0.9, x0: 0.0, y0: 0.0, x1: 20.0, y1: 20.0}

    send(
      GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)),
      {:inference_detections, 1, [person]}
    )

    publish_pair(1_500, distance_mm: 3000)
    set_clock(5_000)
    :sys.resume(VisionCore.Pipelines.server(Pipeline, :hq_people))

    assert [placed] = detections()
    assert_in_delta placed.z, 3.0, 1.0e-6
  end

  test "a stray :pair_wait places nothing before the boxes' pair comes", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    await_boxes()

    send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)), :pair_wait)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
  end

  test "publishes without a distance once the stereo pairs stop for two pair periods",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(10)
    publish_frame(100)
    await_boxes()

    set_clock(19)
    send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)), :pair_wait)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
    set_clock(21)
    send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)), :pair_wait)

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
    send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)), :pair_wait)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
    set_clock(500)
    send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)), :pair_wait)

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

  test "publishes at once, without a distance nor a bearing, the boxes of frames its calibration cannot be projected at",
       %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        start_pipeline(dir, pair_wait_ms: 60_000)
        publish_pair(0)
        publish_pair(1_000)
        # 4:1 frames, against a calibration of 2:1 ones.
        publish_frame(1_400, {40, 10})

        assert [person] = detections()
        assert_no_distance(person)
        assert person.bearing == nil
      end)

    assert log =~ "cannot place detections at 40x10"
  end

  @tag :jpeg
  test "skips the frames whose JPEG does not decode, saying so once, and detects the next", %{
    tmp_dir: dir
  } do
    start_supervised!(VisionCore.Jpeg)
    start_pipeline(dir)
    undecodable = %Frame{label: "hq", width: 40, height: 20, capture_ns: 0, jpeg: "no JPEG"}

    log =
      capture_log(fn ->
        for _frame <- 1..3,
            do: Outputs.publish({:camera_frame, @camera_server}, {:camera_frame, undecodable})

        publish_frame(100)
        assert [_person] = detections()
      end)

    assert length(String.split(log, "cannot detect on the camera hq's images")) == 2
  end

  test "publishes nothing for a frame the backend could not detect on, and detects the next", %{
    tmp_dir: dir
  } do
    start_supervised!(
      {Pipeline,
       name: :hq_people,
       backend: FirstFrameLost,
       source: {:camera, :hq},
       config: config(dir, []),
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:detections, :hq_people})
    publish_frame(100)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
    publish_frame(200)

    assert_receive {:"$gen_cast",
                    {{:detections, :hq_people}, {%Frame{capture_ns: 200_000_000}, [_person]}}}
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

  test "takes a calibration of its camera committed while it runs, from the next frame on",
       %{tmp_dir: dir} do
    start_pipeline(dir)
    publish_frame(100)
    assert [person] = detections()
    assert_bearing(person)

    committed = %{
      calibration()
      | camera_matrix: [200.0, 0.0, 40.5, 0.0, 200.0, 20.5, 0.0, 0.0, 1.0],
        projection_matrix: [200.0, 0.0, 40.5, 0.0, 0.0, 200.0, 20.5, 0.0, 0.0, 0.0, 1.0, 0.0]
    }

    File.write!(Path.join(dir, "hq.yaml"), CameraCalibration.to_yaml(committed, "hq"))

    Outputs.publish(
      VisionCore.Camera.Calibration.changed_key(:hq),
      {:camera_calibration_changed, :hq}
    )

    publish_frame(200)
    assert [person] = detections()
    {azimuth, _elevation} = person.bearing
    assert_in_delta azimuth, :math.atan(-0.1), 1.0e-6
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

  test "says why the stereo depth gives its detections no distance", %{tmp_dir: dir} do
    start_pipeline(dir, files: [:calibration])
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)

    assert VisionCore.CameraPipeline.distances(pipeline) == %{camera: :hq, reason: :no_pose}
  end

  test "says so again once its camera's files are read again", %{tmp_dir: dir} do
    %{components: [{:camera, camera}]} = config(dir, [:calibration])
    pose = Path.join(dir, "hq_pose.yaml")
    config = %VisionCore.Config{components: [{:camera, camera ++ [pose: pose]}]}
    start_pipeline(dir, config: config)
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)
    assert VisionCore.CameraPipeline.distances(pipeline).reason == :no_pose

    File.write!(pose, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0, 0]\n")
    GenServer.cast(pipeline, {:camera_calibration_changed, :hq})

    assert VisionCore.CameraPipeline.distances(pipeline).reason == nil
  end

  test "takes a pose of its camera committed while it runs, from the store", %{tmp_dir: dir} do
    %{components: [{:camera, camera}]} = config(dir, [:calibration])
    store_dir = Path.join(dir, "store")

    config = %VisionCore.Config{
      components: [{:camera, camera ++ [calibration_store_dir: store_dir]}]
    }

    start_pipeline(dir, config: config)
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)
    assert VisionCore.CameraPipeline.distances(pipeline).reason == :no_pose

    pose = %VisionCore.Camera.Pose{
      rotation: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      translation: [0.0, 0.0, 0.0]
    }

    :ok = VisionCore.Camera.Pose.commit(config, :hq, pose)

    assert VisionCore.CameraPipeline.distances(pipeline).reason == nil
  end

  test "says nothing stops the distances of a camera with a calibration and a pose",
       %{tmp_dir: dir} do
    start_pipeline(dir)
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)

    assert VisionCore.CameraPipeline.distances(pipeline) == %{camera: :hq, reason: nil}
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
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
    publish_frame(200)

    assert [] = detections()
  end

  @reply_person %{class_id: 0, score: 0.9, x0: 0.0, y0: 0.0, x1: 20.0, y1: 20.0}

  defp start_held(dir, opts \\ []) do
    {script, opts} = Keyword.pop(opts, :script, [])
    {files, opts} = Keyword.pop(opts, :files, [])
    script = start_supervised!({Agent, fn -> script end})

    start_supervised!(
      {Pipeline,
       [
         name: :hq_people,
         backend: Held,
         backend_server: {self(), script},
         source: {:camera, :hq},
         config: config(dir, files),
         clock: start_clock()
       ] ++ opts}
    )

    :ok = Outputs.subscribe({:detections, :hq_people})
  end

  defp reply(sequence, detections),
    do:
      send(
        GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :hq_people)),
        {:inference_detections, sequence, detections}
      )

  defp assert_published(capture_ms) do
    capture_ns = capture_ms * @ms

    assert_receive {:"$gen_cast",
                    {{:detections, :hq_people}, {%Frame{capture_ns: ^capture_ns}, _detections}}}
  end

  test "keeps a frame that comes while one is in flight, and submits it on the reply, before publishing",
       %{tmp_dir: dir} do
    start_held(dir)
    publish_frame(100)
    assert_receive {:submitted, in_flight}
    publish_frame(200)
    refute_receive {:submitted, _sequence}, 100

    reply(in_flight, [@reply_person])
    assert {:submitted, held} = next_message()
    assert_published(100)
    reply(held, [@reply_person])
    assert_published(200)
  end

  test "times each step of a frame, the wait for its pair left out", %{tmp_dir: dir} do
    start_held(dir, files: [:calibration, :pose], pair_wait_ms: 500)
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)
    publish_pair(0)
    publish_pair(1_000)

    publish_frame(1_400)
    assert_receive {:submitted, in_flight}
    _handed_over = :sys.get_state(pipeline)
    set_clock(10)
    reply(in_flight, [@reply_person])
    await_boxes()
    set_clock(300)
    publish_pair(1_500)
    assert_published(1_400)

    assert Pipeline.stage_times(pipeline) == %{
             input: {0.0, 1},
             inference: {10.0, 1},
             filtering: {0.0, 1},
             placement: {0.0, 1}
           }

    assert Pipeline.stage_times(pipeline) ==
             VisionCore.StageTimes.new([:input, :inference, :filtering, :placement])
  end

  test "times no inference the backend could not answer", %{tmp_dir: dir} do
    start_held(dir)
    pipeline = VisionCore.Pipelines.server(Pipeline, :hq_people)

    publish_frame(100)
    assert_receive {:submitted, in_flight}
    reply(in_flight, nil)

    assert %{input: {_sum_ms, 1}, inference: {+0.0, 0}, placement: {+0.0, 0}} =
             Pipeline.stage_times(pipeline)
  end

  defp next_message do
    receive do
      message -> message
    after
      1_000 -> flunk("no message")
    end
  end

  test "keeps only the newest of the frames that come while one is in flight", %{tmp_dir: dir} do
    start_held(dir)
    publish_frame(100)
    assert_receive {:submitted, in_flight}
    publish_frame(200)
    publish_frame(300)
    refute_receive {:submitted, _sequence}, 100

    reply(in_flight, [])
    assert_published(100)
    assert_receive {:submitted, held}
    refute_receive {:submitted, _another}, 100
    reply(held, [])
    assert_published(300)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
  end

  test "submits the frame kept once the frame in flight could not be detected on", %{
    tmp_dir: dir
  } do
    start_held(dir)
    publish_frame(100)
    assert_receive {:submitted, in_flight}
    publish_frame(200)

    reply(in_flight, nil)
    assert_receive {:submitted, held}
    reply(held, [])
    assert_published(200)
    refute_receive {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}, 100
  end

  test "keeps the frame for the reply in flight, not a late reply to a refused frame", %{
    tmp_dir: dir
  } do
    start_held(dir, script: [{:error, :unavailable}])
    publish_frame(100)
    assert_receive {:submitted, refused}
    publish_frame(200)
    assert_receive {:submitted, in_flight}
    publish_frame(300)

    reply(refused, [])
    refute_receive {:submitted, _sequence}, 100
    refute_received {:"$gen_cast", {{:detections, :hq_people}, {_frame, _detections}}}
    reply(in_flight, [])
    assert_published(200)
    assert_receive {:submitted, held}
    reply(held, [])
    assert_published(300)
  end

  test "drops the frame kept when the backend refuses it, and submits the next at once", %{
    tmp_dir: dir
  } do
    start_held(dir, script: [:ok, {:error, :busy}])
    publish_frame(100)
    assert_receive {:submitted, in_flight}
    publish_frame(200)

    reply(in_flight, [])
    assert_published(100)
    assert_receive {:submitted, _refused}
    refute_receive {:submitted, _sequence}, 100
    publish_frame(300)
    assert_receive {:submitted, next}
    reply(next, [])
    assert_published(300)
  end

  test "with :detect_every_n 2, keeps only every other frame while one is in flight", %{
    tmp_dir: dir
  } do
    start_held(dir, detect_every_n: 2)
    publish_frame(100)
    refute_receive {:submitted, _sequence}, 100
    publish_frame(200)
    assert_receive {:submitted, in_flight}
    publish_frame(300)
    publish_frame(400)
    publish_frame(500)

    reply(in_flight, [])
    assert_published(200)
    assert_receive {:submitted, held}
    reply(held, [])
    assert_published(400)
    refute_receive {:submitted, _another}, 100
  end

  test "drops the frame kept when the reply in flight leaves 32 frames' boxes waiting", %{
    tmp_dir: dir
  } do
    start_held(dir, files: [:calibration, :pose], pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)

    for capture_ms <- 1_001..1_031 do
      publish_frame(capture_ms)
      assert_receive {:submitted, sequence}
      reply(sequence, [@reply_person])
    end

    publish_frame(1_032)
    assert_receive {:submitted, in_flight}
    publish_frame(1_033)
    reply(in_flight, [@reply_person])
    refute_receive {:submitted, _sequence}, 100

    publish_pair(1_100)
    for capture_ms <- 1_001..1_032, do: assert_published(capture_ms)

    publish_frame(1_100)
    assert_receive {:submitted, _next}
  end

  test "declares its input on the camera, and its placement's projection settings" do
    settings = Pipeline.settings(name: :hq_people, source: {:camera, :hq})
    [input, _filtering, placement] = Pipeline.groups(settings)

    assert input.summary =~ "camera hq"
    assert [%{name: "detect_every_n", default: 1}] = input.parameters

    assert Enum.map(placement.parameters, &{&1.name, &1.default}) == [
             {"depth_sample_fraction", 0.5},
             {"reprojection_stride", 3},
             {"pair_wait_ms", 500}
           ]
  end

  describe "with the parameters registry" do
    alias VisionCore.Parameters.MemoryStore

    defp start_registry(saved) do
      start_supervised!({MemoryStore, saved})
      start_supervised!({VisionCore.Parameters, store: MemoryStore})
    end

    # The pipeline declares once it runs; the registry then applies the saved values.
    defp await_declared do
      :sys.get_state(VisionCore.Pipelines.server(Pipeline, :hq_people))
      :sys.get_state(VisionCore.Parameters)
    end

    test "a setting changed through its parameter applies from the next frame", %{tmp_dir: dir} do
      start_registry(%{})
      start_pipeline(dir)
      await_declared()
      publish_pair(0)
      publish_pair(100)
      publish_frame(100)
      assert [%{label: "person"}] = detections()

      assert {:ok, %{value: 1.0}} =
               VisionCore.Parameters.set("hq_people.filtering.min_score", 1.0)

      publish_frame(200)

      assert detections() == []
    end

    test "a saved setting reaches a pipeline as it starts", %{tmp_dir: dir} do
      start_registry(%{"hq_people.filtering.max_detections" => 0})
      start_pipeline(dir)
      await_declared()
      publish_pair(0)
      publish_pair(100)
      publish_frame(100)

      assert detections() == []
    end

    test "a shorter wait for the pair applies to the boxes that come back from then on",
         %{tmp_dir: dir} do
      start_registry(%{})
      start_pipeline(dir, pair_wait_ms: 60_000)
      await_declared()
      publish_pair(0)
      publish_pair(1_000)

      assert {:ok, %{value: 0}} = VisionCore.Parameters.set("hq_people.placement.pair_wait_ms", 0)
      publish_frame(1_400)

      # With the 60 s it started with, the boxes wait for the pair captured after the frame.
      assert [%{label: "person"}] = detections()
    end
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
