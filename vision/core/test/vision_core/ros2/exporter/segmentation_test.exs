defmodule VisionCore.Ros2.Exporter.SegmentationTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, Image, PointCloud2}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.{CameraCalibration, Stamp}
  alias VisionCore.Ros2.Exporter.Segmentation
  alias VisionCore.Segmentation.Pipeline

  @capture_ns 1_234_567_890
  @pair_capture_ns 1_200_000_000

  defp frame(frame_id \\ "hq_optical"),
    do: %Frame{label: "hq", frame_id: frame_id, width: 8, height: 6, capture_ns: @capture_ns}

  # A 4 x 2 grid over the frame's bottom band: sky on the top row, road on the bottom one.
  defp labels,
    do: %{width: 4, height: 2, data: <<10, 10, 10, 10, 0, 0, 0, 0>>, band: {0, 2, 8, 4}}

  defp xyz(points),
    do:
      for(
        {x, y, z} <- points,
        into: <<>>,
        do: <<x::float-32-little, y::float-32-little, z::float-32-little>>
      )

  defp clouds(frame_id \\ "stereo_left_optical"),
    do: %{
      road: xyz([{0.5, 1.0, 4.0}, {-0.5, 1.0, 4.5}]),
      off_road: xyz([{0.0, -2.0, 9.0}]),
      frame_id: frame_id,
      capture_ns: @pair_capture_ns
    }

  defp settings(options \\ []),
    do:
      Segmentation.new(
        [pipeline: :road, camera_frame_id: "hq_frame", cloud_frame_id: "front_left"] ++ options
      )

  defp calibration(model, {fx, fy, cx, cy}, coefficients, {width, height}, skew \\ 0.0) do
    %CameraCalibration{
      width: width,
      height: height,
      distortion_model: model,
      distortion_coefficients: coefficients,
      camera_matrix: [fx, skew, cx, 0.0, fy, cy, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [fx, skew, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  defp by_topic(messages),
    do: Map.new(messages, fn {topic, _module, message} -> {topic, message} end)

  test "publishes on <name>/labels, camera_info, road/points and off_road/points" do
    settings = settings()

    assert settings.labels_topic == "road/labels"
    assert settings.camera_info_topic == "road/camera_info"
    assert settings.road_topic == "road/road/points"
    assert settings.off_road_topic == "road/off_road/points"
  end

  test "publishes under <prefix>/<name>/ with a :topic_prefix" do
    settings = settings(topic_prefix: "front")

    assert settings.labels_topic == "front/road/labels"
    assert settings.camera_info_topic == "front/road/camera_info"
    assert settings.road_topic == "front/road/road/points"
    assert settings.off_road_topic == "front/road/off_road/points"
  end

  test "refuses an option it does not take" do
    assert_raise ArgumentError, ~r/:topic/, fn ->
      Segmentation.new(pipeline: :road, topic: "a")
    end
  end

  test "the label image is a mono8 image of the grid's class ids, in the camera's frame at its capture time" do
    assert [{"road/labels", Image, image} | _others] =
             Segmentation.messages(frame(), labels(), clouds(), settings())

    assert image == %Image{
             header: %Header{
               stamp: Stamp.stamp_from_monotonic(@capture_ns),
               frame_id: "hq_optical"
             },
             height: 2,
             width: 4,
             encoding: "mono8",
             is_bigendian: 0,
             step: 4,
             data: <<10, 10, 10, 10, 0, 0, 0, 0>>
           }
  end

  test "the clouds are the road and off-road points in the stereo left frame, at their pair's capture time" do
    assert [
             _labels,
             _camera_info,
             {"road/road/points", PointCloud2, road},
             {"road/off_road/points", PointCloud2, off_road}
           ] = Segmentation.messages(frame(), labels(), clouds(), settings())

    header = %Header{
      stamp: Stamp.stamp_from_monotonic(@pair_capture_ns),
      frame_id: "stereo_left_optical"
    }

    assert road == %PointCloud2{
             header: header,
             height: 1,
             width: 2,
             fields: PointCloud2.xyz_fields(),
             is_bigendian: 0,
             point_step: 12,
             row_step: 24,
             data: clouds().road,
             is_dense: 1
           }

    assert %PointCloud2{header: ^header, width: 1, row_step: 12, data: data} = off_road
    assert data == clouds().off_road
  end

  test "a result without clouds publishes its label image and its camera info alone" do
    assert [{"road/labels", Image, _image}, {"road/camera_info", CameraInfo, _info}] =
             Segmentation.messages(frame(), labels(), nil, settings())
  end

  test "a result whose points all fall outside the band publishes empty clouds, which encode" do
    empty = %{clouds() | road: <<>>, off_road: <<>>}
    messages = by_topic(Segmentation.messages(frame(), labels(), empty, settings()))

    assert %PointCloud2{width: 0, row_step: 0, data: <<>>} =
             road = messages["road/road/points"]

    assert %PointCloud2{width: 0} = messages["road/off_road/points"]
    assert is_binary(PointCloud2.encode(road))
  end

  test "a frame or a pair without a frame id takes the camera's and the stereo left one's" do
    messages = by_topic(Segmentation.messages(frame(nil), labels(), clouds(nil), settings()))

    assert messages["road/labels"].header.frame_id == "hq_frame"
    assert messages["road/camera_info"].header.frame_id == "hq_frame"
    assert messages["road/road/points"].header.frame_id == "front_left"
    assert messages["road/off_road/points"].header.frame_id == "front_left"
  end

  test "frame ids default to the camera's optical frame and the default stereo unit's left one" do
    settings = Segmentation.new(pipeline: :road, camera: :hq, topic_prefix: "front")
    messages = by_topic(Segmentation.messages(frame(nil), labels(), clouds(nil), settings))

    assert messages["front/road/labels"].header.frame_id == "hq_optical"
    assert messages["front/road/road/points"].header.frame_id == "stereo_left"
  end

  describe "the label image's camera info" do
    test "goes with every label image, under its header, the size of the grid" do
      calibration =
        calibration("plumb_bob", {8.0, 8.0, 3.5, 2.5}, [0.0, 0.0, 0.0, 0.0, 0.0], {8, 6})

      assert [{_labels, Image, image}, {"road/camera_info", CameraInfo, info}] =
               Segmentation.messages(frame(), labels(), nil, settings(calibration: calibration))

      assert info.header == image.header
      assert {info.width, info.height} == {4, 2}
      assert {info.binning_x, info.binning_y, info.roi.width, info.roi.height} == {0, 0, 0, 0}
      assert info.distortion_model == "plumb_bob"
      assert info.r == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    end

    test "is empty but for its size without a calibration, or with one of another aspect ratio" do
      header = %Header{stamp: Stamp.stamp_from_monotonic(@capture_ns), frame_id: "hq_optical"}
      other_ratio = calibration("plumb_bob", {8.0, 8.0, 3.5, 2.5}, [0.0], {8, 8})

      for calibration <- [nil, other_ratio] do
        assert [_labels, {_topic, CameraInfo, info}] =
                 Segmentation.messages(frame(), labels(), nil, settings(calibration: calibration))

        assert info == %CameraInfo{header: header, width: 4, height: 2}
      end
    end

    # A frame wider than 2:1 is all band, stretched more across than down onto the model's grid.
    test "maps the resampled intrinsics onto the grid, skew and each axis's scale apart" do
      calibration =
        calibration("plumb_bob", {500.0, 480.0, 499.5, 199.5}, [0.0], {1000, 400}, 2.0)

      frame = %Frame{frame() | width: 2000, height: 800}
      band = Pipeline.band(2000, 800, 1.0)
      assert band == {0, 0, 2000, 800}
      labels = %{width: 256, height: 128, data: :binary.copy(<<0>>, 256 * 128), band: band}

      assert [_labels, {_topic, CameraInfo, info}] =
               Segmentation.messages(frame, labels, nil, settings(calibration: calibration))

      {sx, sy} = {256 / 2000, 128 / 800}
      # Resampled to the frame first: 2000 x 800 is twice the calibration's size.
      {fx, fy, skew, cx, cy} = {1000.0, 960.0, 4.0, 999.5, 399.5}

      expected_k = [
        fx * sx,
        skew * sx,
        (cx + 0.5) * sx - 0.5,
        0.0,
        fy * sy,
        (cy + 0.5) * sy - 0.5,
        0.0,
        0.0,
        1.0
      ]

      assert_all_in_delta(info.k, expected_k)
      [k0, k1, k2, k3, k4, k5, k6, k7, k8] = info.k
      assert_all_in_delta(info.p, [k0, k1, k2, 0.0, k3, k4, k5, 0.0, k6, k7, k8, 0.0])
    end

    test "on a 1014 x 760 output averaged 2 x 2, maps a 2028 x 1520 calibration onto the grid" do
      calibration =
        calibration("plumb_bob", {1161.3, 1161.3, 1013.5, 759.5}, [0.0], {2028, 1520})

      frame = %Frame{frame() | width: 1014, height: 760}
      {x, y, w, h} = band = Pipeline.band(1014, 760, 1.0)
      assert band == {0, 253, 1014, 507}
      labels = %{width: 256, height: 128, data: :binary.copy(<<0>>, 256 * 128), band: band}

      assert [_labels, {_topic, CameraInfo, info}] =
               Segmentation.messages(frame, labels, nil, settings(calibration: calibration))

      {sx, sy} = {256 / w, 128 / h}
      # The output's own intrinsics: f / 2, (c + 1/2) / 2 - 1/2.
      {fx, cx, cy} = {580.65, 506.5, 379.5}

      assert_all_in_delta(info.k, [
        fx * sx,
        0.0,
        (cx - x + 0.5) * sx - 0.5,
        0.0,
        fx * sy,
        (cy - y + 0.5) * sy - 0.5,
        0.0,
        0.0,
        1.0
      ])
    end

    for {model, coefficients, focal} <- [
          {"plumb_bob", [-0.05, 0.01, 1.0e-3, -1.0e-3, 0.0], 600.0},
          {"equidistant", [0.03, -0.01, 4.0e-3, -1.0e-3], 900.0}
        ] do
      @model model
      @coefficients coefficients
      @focal focal

      test "a point lands in the label pixel of the cell the pipeline puts it in, at the band's corners (#{model})" do
        calibration =
          calibration(@model, {@focal, @focal * 0.98, 321.0, 238.0}, @coefficients, {640, 480})

        # Twice the calibration's size: the camera info starts from it resampled to the frame.
        frame = %Frame{frame() | width: 1280, height: 960}
        {x, y, w, h} = band = Pipeline.band(1280, 960, 1.0)
        {grid_w, grid_h} = {256, 128}
        labels = %{width: grid_w, height: grid_h, data: <<>>, band: band}

        assert [_labels, {_topic, CameraInfo, info}] =
                 Segmentation.messages(frame, labels, nil, settings(calibration: calibration))

        scaled = CameraCalibration.resample_to(calibration, 1280, 960)
        {cell_w, cell_h} = {w / grid_w, h / grid_h}

        # Inside the first cell, near its far corner, inside the last one, and just above the band.
        targets = [
          {{x - 0.5 + 0.2 * cell_w, y - 0.5 + 0.2 * cell_h}, {0, 0}},
          {{x - 0.5 + 0.9 * cell_w, y - 0.5 + 0.9 * cell_h}, {0, 0}},
          {{x + w - 0.5 - 0.2 * cell_w, y + h - 0.5 - 0.2 * cell_h}, {grid_w - 1, grid_h - 1}},
          {{x + 3.0, y - 0.5 - 0.3 * cell_h}, {0, -1}}
        ]

        points = targets |> Enum.map(&elem(&1, 0)) |> rays(scaled)
        on_frame = project(points, scaled.camera_matrix, scaled)
        on_grid = project(points, info.k, scaled)

        Enum.zip_with([targets, on_frame, on_grid], fn [{{u, v}, cell}, {fu, fv}, {gu, gv}] ->
          assert_in_delta fu, u, 1.0e-3
          assert_in_delta fv, v, 1.0e-3

          # The pipeline's cell rule on the frame, and the grid pixel the point lands on.
          assert {floor((fu - x + 0.5) * grid_w / w), floor((fv - y + 0.5) * grid_h / h)} == cell
          assert {floor(gu + 0.5), floor(gv + 0.5)} == cell
          assert_in_delta gu, (fu - x + 0.5) * grid_w / w - 0.5, 1.0e-6
          assert_in_delta gv, (fv - y + 0.5) * grid_h / h - 0.5, 1.0e-6
        end)
      end
    end
  end

  defp assert_all_in_delta(values, expected) do
    assert length(values) == length(expected)
    Enum.zip_with(values, expected, fn value, wanted -> assert_in_delta value, wanted, 1.0e-9 end)
  end

  # The normalised rays through `pixels` of the camera `calibration` describes, as points at z = 1.
  defp rays(pixels, %CameraCalibration{distortion_model: "equidistant"} = calibration) do
    pixels
    |> pixel_mat()
    |> Evision.FishEye.undistortPoints(
      matrix(calibration.camera_matrix),
      coefficients(calibration.distortion_coefficients, 4)
    )
    |> pixel_list()
    |> Enum.map(fn {x, y} -> {x, y, 1.0} end)
  end

  defp rays(pixels, calibration) do
    identity = matrix([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0])

    pixels
    |> pixel_mat()
    |> Evision.undistortPointsIter(
      matrix(calibration.camera_matrix),
      coefficients(calibration.distortion_coefficients, 5),
      identity,
      identity,
      {3, 100, 1.0e-14}
    )
    |> pixel_list()
    |> Enum.map(fn {x, y} -> {x, y, 1.0} end)
  end

  # `points` projected through the camera matrix `k` and `calibration`'s distortion, as OpenCV does.
  defp project(points, k, %CameraCalibration{distortion_model: "equidistant"} = calibration) do
    {pixels, _jacobian} =
      Evision.FishEye.projectPoints(
        points
        |> Enum.map(&[Tuple.to_list(&1)])
        |> Nx.tensor(type: :f64)
        |> Evision.Mat.from_nx()
        |> Evision.Mat.last_dim_as_channel(),
        vector([0.0, 0.0, 0.0]),
        vector([0.0, 0.0, 0.0]),
        matrix(k),
        coefficients(calibration.distortion_coefficients, 4)
      )

    pixel_list(pixels)
  end

  defp project(points, k, calibration) do
    {pixels, _jacobian} =
      Evision.projectPoints(
        points |> Enum.map(&Tuple.to_list/1) |> Nx.tensor(type: :f64) |> Evision.Mat.from_nx_2d(),
        vector([0.0, 0.0, 0.0]),
        vector([0.0, 0.0, 0.0]),
        matrix(k),
        coefficients(calibration.distortion_coefficients, 5)
      )

    pixel_list(pixels)
  end

  defp pixel_mat(pixels) do
    pixels
    |> Enum.map(fn {u, v} -> [[u, v]] end)
    |> Nx.tensor(type: :f64)
    |> Evision.Mat.from_nx()
    |> Evision.Mat.last_dim_as_channel()
  end

  defp pixel_list(pixels),
    do:
      pixels
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.to_list()
      |> Enum.map(fn [[u, v]] -> {u, v} end)

  defp vector(values), do: Evision.Mat.from_nx(Nx.tensor(values, type: :f64))

  defp matrix(values),
    do: values |> Nx.tensor(type: :f64) |> Nx.reshape({3, 3}) |> Evision.Mat.from_nx_2d()

  defp coefficients(values, count) do
    padded = values ++ List.duplicate(0.0, count - length(values))
    Evision.Mat.from_nx_2d(Nx.tensor([padded], type: :f64))
  end
end
