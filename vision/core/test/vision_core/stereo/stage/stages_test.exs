defmodule VisionCore.Stereo.Stage.StagesTest do
  # OpenCV, through evision (a test dependency), is the reference the
  # stages are measured against.
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NxSegment, Pair, Pipeline, Stage}

  @calibration Path.expand("../../../support/calibration", __DIR__)

  defp context(calibration, width, height, frame_size \\ nil) do
    {frame_width, frame_height} = frame_size || {width, height}

    Pipeline.context(
      left_calibration_path: Path.join(@calibration, "#{calibration}_left.yaml"),
      right_calibration_path: Path.join(@calibration, "#{calibration}_right.yaml"),
      width: width,
      height: height,
      frame_width: frame_width,
      frame_height: frame_height
    )
  end

  # Runs Nx `stages` as one segment on `pair`.
  defp run_nx(stages, context, pair) do
    members =
      for {module, opts} <- stages do
        {:ok, state} = module.init(opts, context)
        %{module: module, name: module, state: state}
      end

    {:ok, segment} = NxSegment.build(members, context, compiler: EXLA)
    {:ok, pair, _segment} = NxSegment.run(%{pair | geometry: context}, segment)
    pair
  end

  defp frame(image) do
    {height, width} = Nx.shape(image)
    %Frame{label: "left", grey: Nx.to_binary(image), width: width, height: height, capture_ns: 0}
  end

  defp texture(height, width, seed) do
    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(seed), 0, 256, shape: {height, width}, type: :s32)

    Nx.as_type(texture, :u8)
  end

  # Smooth enough that bilinear sampling differs from OpenCV's fixed point
  # by rounding only.
  defp smooth(height, width) do
    x = Nx.iota({height, width}, axis: 1, type: :f32)
    y = Nx.iota({height, width}, axis: 0, type: :f32)

    Nx.add(128, Nx.multiply(60, Nx.sin(Nx.divide(x, 7))))
    |> Nx.add(Nx.multiply(60, Nx.cos(Nx.divide(y, 9))))
    |> Nx.clip(0, 255)
    |> Nx.round()
    |> Nx.as_type(:u8)
  end

  defp to_tensor(mat), do: mat |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.squeeze()

  defp max_difference(a, b) do
    Nx.subtract(Nx.as_type(a, :f32), Nx.as_type(b, :f32))
    |> Nx.abs()
    |> Nx.reduce_max()
    |> Nx.to_number()
  end

  # OpenCV's rectification maps, CV_16SC2 and its fraction table.
  defp opencv_maps(%CameraCalibration{} = calibration) do
    matrix = fn values -> values |> Nx.tensor(type: :f64) |> Nx.reshape({3, 3}) end
    p = calibration.projection_matrix
    p3 = Enum.map([0, 1, 2, 4, 5, 6, 8, 9, 10], &Enum.at(p, &1))
    d = Enum.take(calibration.distortion_coefficients ++ List.duplicate(0.0, 5), 5)

    Evision.initUndistortRectifyMap(
      Evision.Mat.from_nx_2d(matrix.(calibration.camera_matrix)),
      Evision.Mat.from_nx_2d(Nx.tensor([d], type: :f64)),
      Evision.Mat.from_nx_2d(matrix.(calibration.rectification_matrix)),
      Evision.Mat.from_nx_2d(matrix.(p3)),
      {calibration.width, calibration.height},
      Evision.Constant.cv_16SC2()
    )
  end

  describe "against OpenCV" do
    test "Decode shrinks 768x432 frames to 480x270 as INTER_AREA does" do
      context = context(:stereo, 480, 270, {768, 432})
      image = texture(432, 768, 1)

      pair =
        run_nx([{Stage.Decode, []}], context, %Pair{
          left_frame: frame(image),
          right_frame: frame(image)
        })

      reference =
        image
        |> Evision.Mat.from_nx_2d()
        |> Evision.resize({480, 270}, interpolation: Evision.Constant.cv_INTER_AREA())
        |> to_tensor()

      assert Nx.shape(pair.left) == {270, 480}
      assert max_difference(pair.left, reference) <= 1
    end

    test "Decode passes frames of the pipeline's size through" do
      context = context(:stereo, 64, 48)
      image = texture(48, 64, 2)

      pair =
        run_nx([{Stage.Decode, []}], context, %Pair{
          left_frame: frame(image),
          right_frame: frame(image)
        })

      assert Nx.to_list(pair.left) == Nx.to_list(image)
    end

    test "Rectify rectifies as initUndistortRectifyMap and remap do" do
      context = context(:stereo, 480, 270)
      image = smooth(270, 480)

      pair =
        run_nx([{Stage.Rectify, []}], context, %Pair{
          left_frame: frame(image),
          right_frame: frame(image)
        })

      for {rectified, calibration} <- [
            {pair.left, context.left_calibration},
            {pair.right, context.right_calibration}
          ] do
        {map1, map2} = opencv_maps(calibration)

        reference =
          image
          |> Evision.Mat.from_nx_2d()
          |> Evision.remap(map1, map2, Evision.Constant.cv_INTER_LINEAR())
          |> to_tensor()

        difference = Nx.subtract(Nx.as_type(rectified, :s16), Nx.as_type(reference, :s16))
        within_one = difference |> Nx.abs() |> Nx.less_equal(1) |> Nx.mean() |> Nx.to_number()
        assert within_one >= 0.999
      end
    end

    test "Rectify shrinks 768x432 frames to 480x270 close to INTER_AREA then remap" do
      context = context(:stereo, 480, 270, {768, 432})
      image = smooth(432, 768)

      pair =
        run_nx([{Stage.Rectify, []}], context, %Pair{
          left_frame: frame(image),
          right_frame: frame(image)
        })

      assert Nx.shape(pair.left) == {270, 480}

      shrunk =
        image
        |> Evision.Mat.from_nx_2d()
        |> Evision.resize({480, 270}, interpolation: Evision.Constant.cv_INTER_AREA())

      for {rectified, calibration} <- [
            {pair.left, context.left_calibration},
            {pair.right, context.right_calibration}
          ] do
        {map1, map2} = opencv_maps(calibration)

        reference =
          shrunk |> Evision.remap(map1, map2, Evision.Constant.cv_INTER_LINEAR()) |> to_tensor()

        # Away from the image's edge, where OpenCV blends with a zero border.
        interior = fn t -> t[[20..249, 20..459]] end

        difference =
          Nx.subtract(
            Nx.as_type(interior.(rectified), :s16),
            Nx.as_type(interior.(reference), :s16)
          )

        within_two = difference |> Nx.abs() |> Nx.less_equal(2) |> Nx.mean() |> Nx.to_number()
        assert within_two >= 0.999
      end
    end

    test "PostFilter filters as medianBlur does" do
      context = context(:stereo, 64, 48)
      disparity = Nx.divide(Nx.as_type(texture(48, 64, 3), :f32), 4)
      input = %Pair{left_frame: nil, right_frame: nil, disparity: disparity}
      pair = run_nx([{Stage.PostFilter, []}], context, input)

      reference = disparity |> Evision.Mat.from_nx_2d() |> Evision.medianBlur(5) |> to_tensor()
      assert Nx.to_list(pair.disparity) == Nx.to_list(reference)
    end
  end

  test "Rectify moves the right image by right_row_offset rows, and only it" do
    context = context(:identity, 96, 64)
    image = smooth(64, 96)
    input = %Pair{left_frame: frame(image), right_frame: frame(image)}

    rectify = fn opts ->
      {:ok, state} = Stage.Rectify.init(opts, context)
      member = %{module: Stage.Rectify, name: :rectify, state: state}
      {:ok, segment} = NxSegment.build([member], context, compiler: EXLA)
      {:ok, pair, _segment} = NxSegment.run(%{input | geometry: context}, segment)
      pair
    end

    {plain, shifted} = {rectify.([]), rectify.(right_row_offset: 1.0)}
    assert Nx.to_list(shifted.left) == Nx.to_list(plain.left)
    assert Nx.to_list(shifted.right[[10..50, ..]]) == Nx.to_list(plain.right[[11..51, ..]])

    assert [right_row_offset: %{type: :double}] = Stage.Rectify.option_specs()
    {:ok, state} = Stage.Rectify.init([], context)
    assert {:ok, state} = Stage.Rectify.set_option(state, :right_row_offset, -2.5)
    assert Stage.Rectify.options(state) == %{right_row_offset: -2.5}
    assert {:error, _} = Stage.Rectify.set_option(state, :right_row_offset, 20)
  end

  test "Match aggregates along 8 paths, or 3 when asked" do
    context = context(:identity, 192, 108)
    assert {:ok, opts} = Stage.Match.init([], context)
    assert opts[:paths] == 8
    assert {:ok, opts} = Stage.Match.init([paths: 3], context)
    assert opts[:paths] == 3

    assert {:error, "nx_stereo aggregates along 3 or 8 paths" <> _} =
             Stage.Match.init([paths: 4], context)
  end

  test "Depth and PointCloud measure f·B/d and keep the points from 5 cm to 20 m" do
    context = context(:identity, 192, 108)
    matched = Nx.iota({108, 192}, axis: 1) |> Nx.less(96)
    disparity = Nx.select(matched, 12.0, -1.0)
    input = %Pair{left_frame: nil, right_frame: nil, disparity: disparity}
    pair = run_nx([{Stage.Depth, []}, {Stage.PointCloud, []}], context, input)

    depth_mm = Nx.from_binary(pair.depth, :u16) |> Nx.reshape({108, 192})
    assert Nx.to_number(depth_mm[[0, 0]]) == 1000
    assert Nx.to_number(depth_mm[[0, 191]]) == 0
    assert pair.disparity_bytes == Nx.to_binary(disparity)

    # One point every 4 pixels as an organized grid, NaN outside the matched half.
    assert pair.cloud_size == {27, 48}
    assert byte_size(pair.cloud) == 27 * 48 * 12
    assert pair.cloud_points == 27 * 24
    <<_x::little-float-32, _y::little-float-32, z::little-float-32, _rest::binary>> = pair.cloud
    assert_in_delta z, 1.0, 1.0e-6
    <<_::binary-size(47 * 12 + 8), unmatched_z::binary-size(4), _::binary>> = pair.cloud
    refute match?(<<_::little-float-32>>, unmatched_z)
  end

  describe "the default pipeline" do
    setup do
      Process.flag(:trap_exit, true)
      texture = texture(108, 204, 5)
      {:ok, left: frame(texture[[.., 0..191]]), right: frame(texture[[.., 12..203]])}
    end

    defp start(name) do
      {:ok, pipeline} =
        Pipeline.start_link(
          name: name,
          stages: Pipeline.default_stages(),
          left_calibration_path: Path.join(@calibration, "identity_left.yaml"),
          right_calibration_path: Path.join(@calibration, "identity_right.yaml"),
          width: 192,
          height: 108
        )

      Pipeline.register_listener(pipeline, self())
      pipeline
    end

    defp measure(pipeline, left, right) do
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %Pair{} = pair}}, 60_000
      assert_receive :stereo_pipeline_ready

      depths = pair.depth_m |> Nx.to_flat_list() |> Enum.filter(&(&1 > 0)) |> Enum.sort()

      %{
        share: length(depths) / Nx.size(pair.depth_m),
        median_m: Enum.at(depths, div(length(depths), 2))
      }
    end

    test "measures a known disparity", %{left: left, right: right} do
      measured = start(:known) |> measure(left, right)

      assert_in_delta measured.median_m, 1.0, 0.02
      assert measured.share > 0.8
    end

    test "matches at least as much as OpenCV's StereoSGBM", %{left: left, right: right} do
      measured = start(:against_sgbm) |> measure(left, right)

      [left_mat, right_mat] =
        for frame <- [left, right],
            do: Evision.Mat.from_binary(frame.grey, {:u, 8}, 108, 192, 1)

      sgbm_share =
        Evision.StereoSGBM.create(minDisparity: 0, numDisparities: 64, blockSize: 5)
        |> Evision.StereoSGBM.compute(left_mat, right_mat)
        |> to_tensor()
        |> Nx.greater(0)
        |> Nx.mean()
        |> Nx.to_number()

      assert measured.share >= sgbm_share - 0.10
    end

    @tag :jpeg
    test "decodes JPEG frames, as libcamera and ROS cameras deliver them", %{
      left: left,
      right: right
    } do
      start_supervised!(VisionCore.Jpeg)

      [left, right] =
        for frame <- [left, right] do
          {:ok, jpeg} = VisionCore.Jpeg.encode(frame.grey, frame.width, frame.height, 1, 95)
          %{frame | grey: nil, jpeg: jpeg}
        end

      assert_in_delta measure(start(:jpeg_frames), left, right).median_m, 1.0, 0.05
    end

    @tag :jpeg
    test "a JPEG frame that does not decode fails its pair, the next goes through", %{
      left: left,
      right: right
    } do
      start_supervised!(VisionCore.Jpeg)
      pipeline = start(:bad_jpeg)

      jpeg = %Frame{
        label: "left",
        jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>,
        width: 192,
        height: 108,
        capture_ns: 0
      }

      Pipeline.submit(pipeline, jpeg, jpeg)
      assert_receive :stereo_pipeline_ready, 60_000
      refute_received {:"$gen_cast", {:stereo_pair, _}}

      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %Pair{}}}, 60_000
    end

    test "a featureless pair gives no depth and no points" do
      pipeline = start(:featureless)
      flat = frame(Nx.broadcast(Nx.tensor(90, type: :u8), {108, 192}))

      Pipeline.submit(pipeline, flat, flat)
      assert_receive {:"$gen_cast", {:stereo_pair, %Pair{} = pair}}, 60_000

      assert pair.depth |> :binary.bin_to_list() |> Enum.uniq() == [0]
      assert pair.cloud_points == 0
    end
  end
end
