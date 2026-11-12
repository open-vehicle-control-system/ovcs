defmodule VisionCore.Segmentation.PipelineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Segmentation.Backend.Stub
  alias VisionCore.Segmentation.Pipeline
  alias VisionCore.Stereo.Pair

  @moduletag :tmp_dir
  @moduletag :capture_log

  @camera_server VisionCore.Camera.GStreamer.name_for("hq")
  @ms 1_000_000
  @size 40
  # Cells of 10 columns and 10 rows over a 40 x 20 band: road (0) in the top row's first and
  # last cells and the bottom row's last, sidewalk (1) elsewhere.
  @label_image %{width: 4, height: 2, data: <<0, 1, 1, 0, 1, 1, 1, 0>>}

  # Hands the band it is sent to the test, then answers with the label image.
  defmodule Recorder do
    @behaviour VisionCore.Segmentation.Backend

    def segment({test, labels}, sequence, band) do
      send(test, {:band, band})
      send(self(), {:inference_labels, sequence, labels})
      :ok
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def inference_times(_server), do: nil
  end

  # Tells the test each sequence it is handed and answers what the test scripted, `:ok` once the
  # script is spent; never replies, the test does.
  defmodule Scripted do
    @behaviour VisionCore.Segmentation.Backend

    def segment({test, script}, sequence, _band) do
      send(test, {:submitted, sequence})

      Agent.get_and_update(script, fn
        [answer | rest] -> {answer, rest}
        [] -> {:ok, []}
      end)
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def inference_times(_server), do: nil
  end

  # The pair's rectified intrinsics by default: a stereo pixel lands on the centre of the
  # camera's pixel of the same column and row, which OpenCV puts on integer coordinates.
  defp calibration({cx, cy}) do
    %CameraCalibration{
      width: @size,
      height: @size,
      distortion_model: "plumb_bob",
      distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0],
      camera_matrix: [50.0, 0.0, cx, 0.0, 50.0, cy, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [50.0, 0.0, cx, 0.0, 0.0, 50.0, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  defp config(dir, files, principal_point \\ {20.0, 20.0}) do
    camera =
      [name: :hq, driver: VisionCore.Camera.GStreamer] ++
        for file <- files do
          case file do
            :calibration ->
              path = Path.join(dir, "hq.yaml")
              File.write!(path, CameraCalibration.to_yaml(calibration(principal_point), "hq"))
              {:calibration, path}

            :pose ->
              path = Path.join(dir, "hq_pose.yaml")
              File.write!(path, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0, 0]\n")
              {:pose, path}
          end
        end

    %VisionCore.Config{components: [{:camera, camera}]}
  end

  defp start_pipeline(dir, opts) do
    {label_image, opts} = Keyword.pop(opts, :label_image, @label_image)
    {files, opts} = Keyword.pop(opts, :files, [:calibration, :pose])
    {principal_point, opts} = Keyword.pop(opts, :principal_point, {20.0, 20.0})
    start_supervised!({Stub, pipeline: :road, label_image: label_image})

    start_supervised!(
      {Pipeline,
       [
         name: :road,
         backend: Stub,
         source: {:camera, :hq},
         config: config(dir, files, principal_point),
         clock: start_clock()
       ] ++ opts}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
  end

  # The pipeline's clock, at 0 until a test moves it with `set_clock/1`.
  defp start_clock do
    if Process.whereis(__MODULE__.Clock),
      do: set_clock(0),
      else:
        start_supervised!(%{
          id: :clock,
          start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.Clock]]}
        })

    fn -> Agent.get(__MODULE__.Clock, & &1) end
  end

  defp set_clock(ms), do: Agent.update(__MODULE__.Clock, fn _now_ns -> ms * @ms end)

  # A pair captured at `capture_ms` measuring 2 m at each of `pixels`, `{column, row}`, or at
  # every pixel without them.
  defp publish_pair(capture_ms, pixels \\ :all) do
    frame = %Frame{label: "left", width: @size, height: @size, capture_ns: capture_ms * @ms}

    depth =
      for row <- 0..(@size - 1),
          column <- 0..(@size - 1),
          into: <<>>,
          do: <<if(pixels == :all or {column, row} in pixels, do: 2000, else: 0)::little-16>>

    pair = %Pair{
      left_frame: %Frame{frame | frame_id: "stereo_left_optical"},
      right_frame: %Frame{frame | label: "right"},
      left: Nx.broadcast(Nx.u8(0), {@size, @size}),
      depth: depth,
      geometry: %{principal_point: {20.0, 20.0}, focal_length_px: 50.0}
    }

    Outputs.publish({:stereo_pair, VisionCore.Stereo.Pipeline}, {:stereo_pair, pair})
  end

  # Each pixel's red byte its row, so a band's first byte names its first row.
  defp publish_frame(capture_ms, opts \\ []) do
    {width, height} = Keyword.get(opts, :size, {@size, @size})

    image =
      if opts[:grey],
        do: [grey: :binary.copy(<<0>>, width * height)],
        else: [
          rgb: for(row <- 0..(height - 1), _column <- 1..width, into: <<>>, do: <<row, 0, 0>>)
        ]

    frame =
      struct!(
        %Frame{label: "hq", width: width, height: height, capture_ns: capture_ms * @ms},
        [frame_id: "hq_optical"] ++ image
      )

    Outputs.publish(
      Keyword.get(opts, :key, {:camera_frame, @camera_server}),
      {:camera_frame, frame}
    )
  end

  # A camera of twice the pair's size, `:view`, its calibration that size, and `:inference`
  # averaged from it 2 x 2. Resampled exactly, its principal point is 0.3 px right of the pair's:
  # column 9 lands at 9.3, in the first cell; scaled from the corner, at 9.55, in the second.
  defp outputs_config(dir) do
    calibration = %{
      calibration({41.1, 40.5})
      | width: 2 * @size,
        height: 2 * @size,
        camera_matrix: [100.0, 0.0, 41.1, 0.0, 100.0, 40.5, 0.0, 0.0, 1.0],
        projection_matrix: [100.0, 0.0, 41.1, 0.0, 0.0, 100.0, 40.5, 0.0, 0.0, 0.0, 1.0, 0.0]
    }

    calibration_path = Path.join(dir, "hq.yaml")
    File.write!(calibration_path, CameraCalibration.to_yaml(calibration, "hq"))
    pose_path = Path.join(dir, "hq_pose.yaml")
    File.write!(pose_path, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0, 0]\n")

    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      sensor_width: 2 * @size,
      sensor_height: 2 * @size,
      outputs: [
        view: [resolution: {2 * @size, 2 * @size}, processor: :cpu],
        inference: [resolution: {@size, @size}, from: :view]
      ],
      calibration: calibration_path,
      pose: pose_path
    ]

    %VisionCore.Config{components: [{:camera, camera}]}
  end

  test "on a camera's output, takes its band and sorts its points at that output's size",
       %{tmp_dir: dir} do
    road = [{0, 10}, {9, 10}, {39, 10}, {39, 29}]
    off_road = [{10, 10}, {0, 29}]
    outside = [{0, 9}, {39, 9}, {0, 30}, {39, 30}]
    inference = {:camera_frame, VisionCore.Camera.V4L2Single.name_for("hq"), :inference}
    start_supervised!({Stub, pipeline: :road, label_image: @label_image})

    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Stub,
       source: {:camera, :hq, :inference},
       config: outputs_config(dir),
       band_top: 0.25,
       reprojection_stride: 1,
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
    publish_pair(0, road ++ off_road ++ outside)
    publish_pair(100, road ++ off_road ++ outside)
    publish_frame(100, key: inference)

    assert {%{band: {0, 10, 40, 20}}, clouds} = segmentation()
    assert points(clouds.road) == Enum.map(road, &left_point/1)

    assert points(clouds.off_road) ==
             Enum.map(Enum.sort_by(off_road, &elem(&1, 1)), &left_point/1)
  end

  test "on a 1014 x 760 output, sees the 1014 x 507 band touching its bottom" do
    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      outputs: [
        view: [resolution: {2028, 1520}, processor: :cpu],
        inference: [resolution: {1014, 760}, from: :view]
      ]
    ]

    start_supervised!({Stub, pipeline: :road, label_image: @label_image})

    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Stub,
       source: {:camera, :hq, :inference},
       config: %VisionCore.Config{components: [{:camera, camera}]},
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
    inference = {:camera_frame, VisionCore.Camera.V4L2Single.name_for("hq"), :inference}
    publish_frame(100, size: {1014, 760}, key: inference)

    assert {%{band: {0, 253, 1014, 507}}, nil} = segmentation()
  end

  defp segmentation(timeout \\ 1_000) do
    assert_receive {:"$gen_cast", {:segmentation, :road, %Frame{label: "hq"}, labels, clouds}},
                   timeout

    {labels, clouds}
  end

  defp points(cloud) do
    for <<x::float-32-little, y::float-32-little, z::float-32-little <- cloud>>,
      do: {Float.round(x, 4), Float.round(y, 4), Float.round(z, 4)}
  end

  # Where the left pixel `{column, row}` measured at 2 m is in the left optical frame.
  defp left_point({column, row}),
    do: {Float.round((column - 20) * 2 / 50, 4), Float.round((row - 20) * 2 / 50, 4), 2.0}

  test "publishes the label image over the band touching the frame's bottom by default", %{
    tmp_dir: dir
  } do
    start_pipeline(dir, files: [])
    publish_frame(100)

    assert {labels, nil} = segmentation()
    assert labels == Map.put(@label_image, :band, {0, 20, 40, 20})
  end

  test "places the band's top at :band_top, a fraction of the frame's height, and keeps it inside",
       %{tmp_dir: dir} do
    for {band_top, band} <- [
          {0.25, {0, 10, 40, 20}},
          {0.0, {0, 0, 40, 20}},
          {1.0, {0, 20, 40, 20}}
        ] do
      start_pipeline(dir, files: [], band_top: band_top)
      publish_frame(100)

      assert {%{band: ^band}, nil} = segmentation()
      stop_supervised!(Pipeline)
      stop_supervised!(Stub)
    end
  end

  test "publishes the frame without its pixels", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    publish_pair(1_500)

    assert_receive {:"$gen_cast",
                    {:segmentation, :road, %Frame{rgb: nil, frame_id: "hq_optical"}, _labels, %{}}}
  end

  test "takes the whole frame as its band when the frame is wider than 2:1", %{tmp_dir: dir} do
    start_pipeline(dir, files: [])
    publish_frame(100, size: {40, 10})

    assert {%{band: {0, 0, 40, 10}}, nil} = segmentation()
  end

  test "hands the backend the band's rows only", %{tmp_dir: dir} do
    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Recorder,
       backend_server: {self(), @label_image},
       source: {:camera, :hq},
       band_top: 0.25,
       config: config(dir, [])}
    )

    publish_frame(100)

    assert_receive {:band, %{width: 40, height: 20, rgb: rgb}}
    assert byte_size(rgb) == 40 * 20 * 3
    assert <<10, 0, 0, _rest::binary>> = rgb
    assert binary_part(rgb, byte_size(rgb) - 3, 3) == <<29, 0, 0>>
  end

  test "sorts the matched pair's points into road and off-road by the cell they land in, exact at the band's edges",
       %{tmp_dir: dir} do
    road = [{0, 10}, {9, 10}, {39, 10}, {39, 29}]
    off_road = [{10, 10}, {0, 29}]
    outside = [{0, 9}, {39, 9}, {0, 30}, {39, 30}]

    start_pipeline(dir, band_top: 0.25, reprojection_stride: 1)
    publish_pair(0, road ++ off_road ++ outside)
    publish_pair(100, road ++ off_road ++ outside)
    publish_frame(100)

    assert {%{band: {0, 10, 40, 20}}, clouds} = segmentation()
    assert points(clouds.road) == Enum.map(road, &left_point/1)

    assert points(clouds.off_road) ==
             Enum.map(Enum.sort_by(off_road, &elem(&1, 1)), &left_point/1)

    assert clouds.frame_id == "stereo_left_optical"
  end

  # Cell c covers the band's pixel centres c * 10 to c * 10 + 9: u from c * 10 - 0.5 to c * 10 + 9.5.
  test "puts a point in the cell whose pixel centres it is nearest, a sub-pixel off the pair's",
       %{tmp_dir: dir} do
    pixels = [{0, 10}, {9, 10}, {29, 10}, {39, 10}]
    start_pipeline(dir, band_top: 0.25, reprojection_stride: 1, principal_point: {20.8, 20.0})
    publish_pair(0, pixels)
    publish_pair(100, pixels)
    publish_frame(100)

    # At u = 0.8, 9.8, 29.8 and 39.8: cells 0 (road), 1, 3 (road), and past the grid's last.
    assert {_labels, clouds} = segmentation()
    assert points(clouds.road) == Enum.map([{0, 10}, {29, 10}], &left_point/1)
    assert points(clouds.off_road) == [left_point({9, 10})]
  end

  test "publishes without clouds at once, without waiting, frames its calibration cannot be projected at",
       %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        start_pipeline(dir, pair_wait_ms: 60_000)
        publish_pair(0)
        publish_pair(1_000)
        # 4:1 frames, against a calibration of square ones.
        publish_frame(1_400, size: {40, 10})

        assert {%{band: {0, 0, 40, 10}}, nil} = segmentation()
      end)

    assert log =~ "cannot project the stereo points at 40x10"
  end

  test "takes :road_classes as road, every other class as off-road", %{tmp_dir: dir} do
    start_pipeline(dir,
      band_top: 0.25,
      road_classes: ["road", "sidewalk"],
      reprojection_stride: 1
    )

    publish_pair(0, [{0, 10}, {10, 10}])
    publish_pair(100, [{0, 10}, {10, 10}])
    publish_frame(100)

    assert {_labels, %{road: road, off_road: <<>>}} = segmentation()
    assert length(points(road)) == 2
  end

  test "publishes the label image without clouds at once while no pair came", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_frame(100)

    assert {%{width: 4}, nil} = segmentation()
  end

  test "publishes the label image without clouds once the stereo pairs stop for two pair periods",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(10)
    publish_frame(100)
    await_labels()

    set_clock(19)
    send(Pipeline.Road, :pair_wait)
    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
    set_clock(21)
    send(Pipeline.Road, :pair_wait)

    assert {%{width: 4}, nil} = segmentation()
  end

  test "publishes the label image without clouds once it waited pair_wait_ms", %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 500)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_600)
    await_labels()

    set_clock(499)
    send(Pipeline.Road, :pair_wait)
    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
    set_clock(500)
    send(Pipeline.Road, :pair_wait)

    assert {%{width: 4}, nil} = segmentation()
  end

  # The first call lets the frame's labels reach the pipeline, the second has them handled.
  defp await_labels do
    _submitted = :sys.get_state(Pipeline.Road)
    _handled = :sys.get_state(Pipeline.Road)
  end

  test "segments the frames that come while label images wait, publishing each in capture order with clouds",
       %{tmp_dir: dir} do
    start_pipeline(dir, pair_wait_ms: 60_000)
    publish_pair(0)
    publish_pair(1_000)
    publish_frame(1_400)
    await_labels()
    publish_frame(1_900)
    await_labels()

    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
    publish_pair(1_500)
    publish_pair(2_000)

    assert_receive {:"$gen_cast",
                    {:segmentation, :road, %Frame{capture_ns: 1_400_000_000}, _labels, first}}

    assert_receive {:"$gen_cast",
                    {:segmentation, :road, %Frame{capture_ns: 1_900_000_000}, _labels, second}}

    assert %{road: <<_road::binary>>} = first
    assert %{road: <<_road_too::binary>>} = second

    # The clouds carry the capture time of the pair matched with each frame.
    assert first.capture_ns == 1_500_000_000
    assert second.capture_ns == 2_000_000_000
  end

  test "skips the frames that come while 32 frames' label images wait for their pair", %{
    tmp_dir: dir
  } do
    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Recorder,
       backend_server: {self(), @label_image},
       source: {:camera, :hq},
       pair_wait_ms: 60_000,
       config: config(dir, [:calibration, :pose]),
       clock: start_clock()}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
    publish_pair(0)
    publish_pair(1_000)

    for capture_ms <- 1_001..1_033 do
      publish_frame(capture_ms)
      await_labels()
    end

    for _sent <- 1..32, do: assert_received({:band, _band})
    refute_received {:band, _next}
    publish_pair(1_100)

    for capture_ms <- 1_001..1_032 do
      capture_ns = capture_ms * @ms

      assert_receive {:"$gen_cast",
                      {:segmentation, :road, %Frame{capture_ns: ^capture_ns}, _labels, %{}}}
    end

    publish_frame(1_100)
    assert_receive {:band, _band}
  end

  test "a camera without a pose publishes no clouds, without waiting, saying so once", %{
    tmp_dir: dir
  } do
    log =
      capture_log(fn ->
        start_pipeline(dir, files: [:calibration], pair_wait_ms: 60_000)
        publish_pair(0)
        publish_pair(100)
        publish_frame(100)
        assert {_labels, nil} = segmentation()
      end)

    assert [_once] = Regex.scan(~r/camera hq has no pose, so its segmentation has no clouds/, log)
  end

  test "skips the frames without colour, saying so once", %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        start_pipeline(dir, files: [])
        publish_frame(100, grey: true)
        publish_frame(200, grey: true)
        refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
      end)

    assert [_once] = Regex.scan(~r/camera hq's images have no colour/, log)
  end

  test "publishes nothing for a frame the backend could not segment", %{tmp_dir: dir} do
    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Recorder,
       backend_server: {self(), nil},
       source: {:camera, :hq},
       config: config(dir, [])}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
    publish_frame(100)

    assert_receive {:band, _band}
    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
  end

  defp start_scripted(dir, script) do
    script = start_supervised!({Agent, fn -> script end})

    start_supervised!(
      {Pipeline,
       name: :road,
       backend: Scripted,
       backend_server: {self(), script},
       source: {:camera, :hq},
       config: config(dir, [])}
    )

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
  end

  test "submits no frame while a band is in flight, so its reply is published", %{tmp_dir: dir} do
    start_scripted(dir, [])

    publish_frame(100)
    assert_receive {:submitted, in_flight}
    publish_frame(200)
    refute_receive {:submitted, _sequence}, 100

    send(Pipeline.Road, {:inference_labels, in_flight, @label_image})
    assert_receive {:"$gen_cast", {:segmentation, :road, %Frame{capture_ns: 100_000_000}, _, nil}}
    publish_frame(300)
    assert_receive {:submitted, _next}
  end

  test "drops a late reply to a band the backend refused, matching only the band it took", %{
    tmp_dir: dir
  } do
    start_scripted(dir, [{:error, :unavailable}, :ok])

    publish_frame(100)
    assert_receive {:submitted, refused}
    publish_frame(200)
    assert_receive {:submitted, taken}

    send(Pipeline.Road, {:inference_labels, refused, @label_image})
    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
    send(Pipeline.Road, {:inference_labels, taken, @label_image})
    assert_receive {:"$gen_cast", {:segmentation, :road, %Frame{capture_ns: 200_000_000}, _, nil}}
  end

  test "two pipelines on one camera publish apart, each its own backend's labels", %{tmp_dir: dir} do
    for {name, data} <- [road: <<0>>, lane: <<1>>] do
      server = VisionCore.Detection.server(Stub, name)
      labels = %{width: 1, height: 1, data: data}

      start_supervised!(
        Supervisor.child_spec({Stub, name: server, pipeline: name, label_image: labels},
          id: server
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Pipeline,
           name: name,
           backend: Stub,
           backend_server: server,
           source: {:camera, :hq},
           config: config(dir, [])},
          id: name
        )
      )
    end

    :ok = Outputs.subscribe({:segmentation, Pipeline.Road})
    publish_frame(100)

    assert {%{data: <<0>>}, nil} = segmentation()
    refute_receive {:"$gen_cast", {:segmentation, :lane, _frame, _labels, _clouds}}, 100
    :ok = Outputs.subscribe({:segmentation, Pipeline.Lane})
    publish_frame(200)

    assert_receive {:"$gen_cast", {:segmentation, :lane, _frame, %{data: <<1>>}, nil}}
  end

  test "segments every :segment_every_n-th frame", %{tmp_dir: dir} do
    start_pipeline(dir, files: [], segment_every_n: 2)
    publish_frame(100)
    refute_receive {:"$gen_cast", {:segmentation, _name, _frame, _labels, _clouds}}, 100
    publish_frame(200)

    assert {_labels, nil} = segmentation()
  end

  test "declares its input and classes steps, fixed at start, in its pipeline", %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_pipeline(dir, files: [], band_top: 0.25, road_classes: ["road", "sidewalk"])

    groups = Enum.filter(VisionCore.Parameters.groups(), &(&1.pipeline == :road))

    assert groups |> Enum.map(&{&1.id, &1.position}) |> Enum.sort_by(&elem(&1, 1)) ==
             [{"road.input", 101}, {"road.inference", 102}, {"road.classes", 103}]

    values =
      for group <- groups,
          parameter <- group.parameters,
          into: %{},
          do: {parameter.name, parameter.value}

    assert %{
             "segment_every_n" => 1,
             "band_top" => 0.25,
             "road_classes" => "road, sidewalk",
             "reprojection_stride" => 3,
             "pair_wait_ms" => 500
           } = values
  end

  test "on a camera's output, takes that output's frames" do
    start_supervised!({Stub, pipeline: :road})

    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      outputs: [
        view: [resolution: {2028, 1520}, processor: :cpu],
        inference: [resolution: {1014, 760}, from: :view]
      ]
    ]

    pipeline =
      start_supervised!(
        {Pipeline,
         name: :road,
         backend: Stub,
         source: {:camera, :hq, :inference},
         config: %VisionCore.Config{components: [{:camera, camera}]}}
      )

    server = VisionCore.Camera.V4L2Single.name_for("hq")
    assert pipeline in Outputs.subscribers({:camera_frame, server, :inference})
    refute pipeline in Outputs.subscribers({:camera_frame, server, :view})
  end

  test "refuses a road class its labels do not name, a source that is no camera, and no name", %{
    tmp_dir: dir
  } do
    Process.flag(:trap_exit, true)
    start_supervised!({Stub, pipeline: :road})

    for {opts, message} <- [
          {[name: :road, source: {:camera, :hq}, road_classes: ["raod"]], "\"raod\""},
          {[name: :road, source: :stereo], "{:camera, name}"},
          {[name: :road], "{:camera, name}"},
          {[name: :road, source: {:camera, :hq}, band_top: 1.5], ":band_top"},
          {[name: :road, source: {:camera, :hq}, segment_every_n: 0], ":segment_every_n"},
          {[name: :road, source: {:camera, :hq}, segment_every_n: 1.5], ":segment_every_n"},
          {[name: :road, source: {:camera, :hq}, reprojection_stride: 0], ":reprojection_stride"},
          {[name: :road, source: {:camera, :hq}, pair_wait_ms: -1], ":pair_wait_ms"},
          {[name: :road, source: {:camera, :usb}], ":usb"},
          {[name: :road, source: {:camera, :hq, :inference}],
           "the output :inference of the camera :hq, which has no named outputs"},
          {[source: {:camera, :hq}], ":name"}
        ] do
      assert {:error, {%ArgumentError{message: refused}, _stacktrace}} =
               Pipeline.start_link([backend: Stub, config: config(dir, [])] ++ opts)

      assert refused =~ message
    end
  end
end
