defmodule VisionCore.Detection.FusionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection.Fusion

  # A hand-built depth image from `rows` in metres, as the pipeline's
  # millimetres, so the expected answer is arithmetic.
  defp depth_map(rows) do
    size = {rows |> hd() |> length(), length(rows)}
    binary = for value <- List.flatten(rows), into: <<>>, do: <<round(value * 1000)::little-16>>
    {binary, size}
  end

  defp median_depth({binary, size}, box, fraction),
    do: Fusion.median_depth(binary, size, box, fraction)

  defp box(x0, y0, x1, y1), do: %{x0: x0 / 1.0, y0: y0 / 1.0, x1: x1 / 1.0, y1: y1 / 1.0}

  describe "median_depth/4" do
    test "takes the median over the central fraction of the box" do
      # 8x8 of 5.0 m with a 4x4 block of 2.0 m in the middle. With
      # fraction 0.5 the sample window is exactly that middle block.
      rows =
        for y <- 0..7 do
          for x <- 0..7 do
            if x in 2..5 and y in 2..5, do: 2.0, else: 5.0
          end
        end

      assert median_depth(depth_map(rows), box(0, 0, 8, 8), 0.5) == 2.0
    end

    test "ignores the background a whole-box sample would include" do
      # Same map, but sampling the entire box sees 48 background
      # pixels against 16 foreground ones — the median lands on the
      # wall behind, which is the failure the central sample avoids.
      rows =
        for y <- 0..7 do
          for x <- 0..7 do
            if x in 2..5 and y in 2..5, do: 2.0, else: 5.0
          end
        end

      assert median_depth(depth_map(rows), box(0, 0, 8, 8), 1.0) == 5.0
    end

    test "treats zero as no measurement rather than as 0 m" do
      # Half the window unmeasured. A mean over raw values would give
      # 1.0 m; the median over valid ones is the real 2.0 m.
      rows = [
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 2.0, 2.0, 0.0],
        [0.0, 2.0, 2.0, 0.0],
        [0.0, 0.0, 0.0, 0.0]
      ]

      assert median_depth(depth_map(rows), box(0, 0, 4, 4), 1.0) == 2.0
    end

    test "returns nil when nothing inside the box was measured" do
      rows = for _ <- 0..3, do: for(_ <- 0..3, do: 0.0)
      assert median_depth(depth_map(rows), box(0, 0, 4, 4), 1.0) == nil
    end

    test "clamps a box that runs off the edge of the frame" do
      rows = for _ <- 0..3, do: for(_ <- 0..3, do: 3.0)
      # A person cut off at the right edge: x1 beyond the width.
      assert median_depth(depth_map(rows), box(2, 0, 40, 4), 1.0) == 3.0
    end

    test "reads the box's rows, not the image's first ones" do
      rows = [[9.0, 9.0, 9.0], [9.0, 9.0, 9.0], [9.0, 1.5, 9.0]]
      assert median_depth(depth_map(rows), box(1, 2, 2, 3), 1.0) == 1.5
    end

    test "averages the two middle values for an even sample count" do
      rows = [[1.0, 2.0], [3.0, 4.0]]
      assert median_depth(depth_map(rows), box(0, 0, 2, 2), 1.0) == 2.5
    end
  end

  describe "unproject/4" do
    test "a box on the principal point sits straight ahead" do
      geometry = Fusion.unproject(box(90, 40, 110, 60), 2.0, {100.0, 50.0}, 400.0)

      assert_in_delta geometry.x, 0.0, 1.0e-9
      assert_in_delta geometry.y, 0.0, 1.0e-9
      assert geometry.z == 2.0
    end

    test "offsets scale with distance and inversely with focal length" do
      # 40 px right of centre, at 2 m, with fx 400 -> 40 * 2 / 400.
      geometry = Fusion.unproject(box(130, 50, 150, 70), 2.0, {100.0, 50.0}, 400.0)

      assert_in_delta geometry.x, 0.2, 1.0e-9
      assert_in_delta geometry.y, 0.05, 1.0e-9
    end

    test "metric size comes from pixel size at that distance" do
      # 20 px wide, 60 px tall at 3 m with fx 400.
      geometry = Fusion.unproject(box(0, 0, 20, 60), 3.0, {100.0, 50.0}, 400.0)

      assert_in_delta geometry.width, 20 * 3.0 / 400.0, 1.0e-9
      assert_in_delta geometry.height, 60 * 3.0 / 400.0, 1.0e-9
    end

    test "y is positive downward, matching the optical frame" do
      # Below the principal point in pixels means +y in an optical
      # frame — the reason a label is drawn at a smaller y.
      geometry = Fusion.unproject(box(90, 90, 110, 110), 2.0, {100.0, 50.0}, 400.0)
      assert geometry.y > 0.0
    end
  end

  describe "perimeter/2" do
    test "walks the corners once, leaving the loop to close itself" do
      assert Fusion.perimeter(box(10, 20, 110, 220), 1) == [
               {10.0, 20.0},
               {110.0, 20.0},
               {110.0, 220.0},
               {10.0, 220.0}
             ]
    end

    test "subdividing gives 4 x segments vertices, with no repeats" do
      vertices = Fusion.perimeter(box(0, 0, 100, 100), 4)

      assert length(vertices) == 16
      # A repeated corner would draw a zero-length segment and, worse,
      # mean the edge counts were wrong.
      assert length(Enum.uniq(vertices)) == 16
    end

    test "subdivision points lie on the edge" do
      [_corner, second | _] = Fusion.perimeter(box(0, 0, 100, 0), 2)
      assert second == {50.0, 0.0}
    end
  end

  describe "raw_pixel/2" do
    @calibration Path.expand("../../support/calibration", __DIR__)

    test "maps a rectified pixel to the raw pixel OpenCV's rectification map gives" do
      calibration =
        @calibration
        |> Path.join("stereo_left.yaml")
        |> VisionCore.Ros2.CameraCalibration.load!()
        |> VisionCore.Ros2.CameraCalibration.scale_to(480, 270)

      {opencv_x, opencv_y} =
        Evision.initUndistortRectifyMap(
          matrix(calibration.camera_matrix),
          Evision.Mat.from_nx_2d(Nx.tensor([calibration.distortion_coefficients], type: :f64)),
          matrix(calibration.rectification_matrix),
          calibration.projection_matrix
          |> then(fn projection ->
            Enum.map([0, 1, 2, 4, 5, 6, 8, 9, 10], &Enum.at(projection, &1))
          end)
          |> matrix(),
          {480, 270},
          Evision.Constant.cv_32FC1()
        )

      {opencv_x, opencv_y} =
        {Evision.Mat.to_nx(opencv_x, Nx.BinaryBackend),
         Evision.Mat.to_nx(opencv_y, Nx.BinaryBackend)}

      for {u, v} <- [{0, 0}, {240, 135}, {479, 269}, {100, 30}] do
        {x, y} = Fusion.raw_pixel(calibration, {u, v})
        assert_in_delta x, Nx.to_number(opencv_x[v][u]), 0.01
        assert_in_delta y, Nx.to_number(opencv_y[v][u]), 0.01
      end
    end
  end

  describe "raw_points/2" do
    alias VisionCore.Camera.Frame
    alias VisionCore.Ros2.CameraCalibration
    alias VisionCore.Stereo.Pair

    test "maps rectified vertices through the left calibration, then to the frame's scale" do
      calibration =
        CameraCalibration.load!(
          Path.expand("../../support/calibration/distorted_left.yaml", __DIR__)
        )

      frame = %Frame{
        label: "left",
        width: calibration.width * 2,
        height: calibration.height * 2,
        capture_ns: 0,
        grey: <<>>
      }

      pair = %Pair{
        left_frame: frame,
        right_frame: frame,
        geometry: %{
          width: calibration.width,
          height: calibration.height,
          left_calibration: calibration
        }
      }

      vertices = [{10.0, 20.0}, {30.5, 40.0}]

      assert Fusion.raw_points(vertices, pair) ==
               Enum.map(vertices, fn vertex ->
                 {x, y} = Fusion.raw_pixel(calibration, vertex)
                 {x * 2, y * 2}
               end)
    end

    test "only scales without a calibration" do
      frame = %Frame{label: "left", width: 960, height: 540, capture_ns: 0, grey: <<>>}

      pair = %Pair{
        left_frame: frame,
        right_frame: frame,
        geometry: %{width: 480, height: 270, left_calibration: nil}
      }

      assert Fusion.raw_points([{120.0, 54.0}], pair) == [{240.0, 108.0}]
    end
  end

  describe "outlines/3" do
    alias VisionCore.Camera.Frame
    alias VisionCore.Ros2.CameraCalibration
    alias VisionCore.Stereo.Pair

    test "outlines each box on the captured frame, through the left calibration's lens model" do
      calibration =
        CameraCalibration.load!(
          Path.expand("../../support/calibration/distorted_left.yaml", __DIR__)
        )

      {width, height} = {calibration.width, calibration.height}
      frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, grey: <<>>}

      pair = %Pair{
        left_frame: frame,
        right_frame: frame,
        geometry: %{width: width, height: height, left_calibration: calibration}
      }

      person = %{x0: width * 0.25, y0: height * 0.2, x1: width * 0.75, y1: height * 0.8}
      car = box(10, 10, 20, 30)

      assert [person_outline, car_outline] = Fusion.outlines([person, car], 2, pair)
      assert person_outline == Fusion.raw_points(Fusion.perimeter(person, 2), pair)
      assert car_outline == Fusion.raw_points(Fusion.perimeter(car, 2), pair)

      [{x, y} | _rest] = person_outline
      assert {x, y} == Fusion.raw_pixel(calibration, {person.x0, person.y0})
      refute_in_delta x, width * 0.25, 1.0e-3
    end

    test "outlines no box without reading the calibration" do
      frame = %Frame{label: "left", width: 960, height: 540, capture_ns: 0, grey: <<>>}

      pair = %Pair{
        left_frame: frame,
        right_frame: frame,
        geometry: %{width: 480, height: 270, left_calibration: %CameraCalibration{}}
      }

      assert Fusion.outlines([], 4, pair) == []
    end
  end

  describe "projected_depths/3" do
    alias VisionCore.Camera.{Frame, Pose}
    alias VisionCore.Detection.Reprojection
    alias VisionCore.Ros2.CameraCalibration
    alias VisionCore.Stereo.Pair

    test "takes the median z of the points inside each box's central fraction" do
      # With fraction 0.5 the first box samples 25..75 on both axes: the 9 m points are
      # inside the box but outside its middle.
      points =
        projected_points([
          {30.0, 30.0, 2.0},
          {50.0, 70.0, 2.4},
          {74.0, 26.0, 2.2},
          {10.0, 50.0, 9.0},
          {50.0, 90.0, 9.5},
          {150.0, 150.0, 4.0}
        ])

      assert Fusion.projected_depths(points, [box(0, 0, 100, 100), box(140, 140, 160, 160)], 0.5) ==
               [f32(2.2), f32(4.0)]
    end

    test "gives no distance to a box with no point inside, nor to one past 90° off-axis" do
      points = projected_points([{50.0, 50.0, -0.5}, {52.0, 50.0, -0.4}, {50.0, 52.0, 0.1}])

      assert Fusion.projected_depths(points, [box(40, 40, 60, 60), box(0, 0, 10, 10)], 1.0) ==
               [nil, nil]
    end

    test "gives no distance to any box without points" do
      assert Fusion.projected_depths(projected_points([]), [box(0, 0, 10, 10)], 1.0) == [nil]
      assert Fusion.projected_depths(projected_points([{5.0, 5.0, 1.0}]), [], 1.0) == []
    end

    test "places a box over a plane at the plane's distance" do
      # A plane 2.5 m ahead of a distorted camera, as the stereo pair measures it from an
      # oblique pose.
      {rotation, _jacobian} =
        Evision.rodrigues(Evision.Mat.from_nx(Nx.tensor([0.1, -0.2, 0.05], type: :f64)))

      pose = %Pose{
        rotation: rotation |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.to_flat_list(),
        translation: [0.12, -0.03, 0.05]
      }

      calibration = %CameraCalibration{
        width: 640,
        height: 480,
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.25, 0.08, 1.0e-3, -1.5e-3, 0.01],
        camera_matrix: [600.0, 0.0, 330.0, 0.0, 590.0, 245.0, 0.0, 0.0, 1.0]
      }

      points = Reprojection.project(plane_pair(pose, 2.5), calibration, pose, 2)

      [distance] = Fusion.projected_depths(points, [box(200, 150, 400, 330)], 0.5)
      assert_in_delta distance, 2.5, 1.0e-3
    end

    defp plane_pair(%Pose{rotation: rotation, translation: [_, _, tz]}, camera_z) do
      [_, _, _, _, _, _, r20, r21, r22] = rotation
      {width, height, focal_length, cx, cy} = {64, 48, 50.0, 32.0, 24.0}

      depth =
        for v <- 0..(height - 1), u <- 0..(width - 1), into: <<>> do
          {x, y} = {(u - cx) / focal_length, (v - cy) / focal_length}
          <<round((camera_z - tz) / (r20 * x + r21 * y + r22) * 1000)::little-16>>
        end

      frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, grey: <<>>}

      %Pair{
        left_frame: frame,
        right_frame: frame,
        depth: depth,
        geometry: %{
          width: width,
          height: height,
          focal_length_px: focal_length,
          principal_point: {cx, cy}
        }
      }
    end
  end

  describe "unproject_camera/3" do
    alias VisionCore.Ros2.CameraCalibration

    test "matches unproject/4 for a lens without distortion" do
      calibration = camera_calibration("plumb_bob", [400.0, 0.0, 100.0, 0.0, 400.0, 50.0], [])
      box = box(130, 50, 150, 110)

      geometry = Fusion.unproject_camera(box, 2.0, calibration)
      expected = Fusion.unproject(box, 2.0, {100.0, 50.0}, 400.0)

      for key <- [:x, :y, :z, :width, :height] do
        assert_in_delta Map.fetch!(geometry, key), Map.fetch!(expected, key), 1.0e-9
      end
    end

    test "places the box centre on the point its pixel sees through the lens's distortion" do
      calibration =
        camera_calibration(
          "plumb_bob",
          [600.0, 0.0, 330.0, 0.0, 590.0, 245.0],
          [-0.25, 0.08, 1.0e-3, -1.5e-3, 0.01]
        )

      {u, v} = opencv_pixel({0.9, -0.6, 2.0}, calibration)
      geometry = Fusion.unproject_camera(box(u - 10, v - 20, u + 10, v + 20), 2.0, calibration)

      assert_in_delta geometry.x, 0.9, 1.0e-6
      assert_in_delta geometry.y, -0.6, 1.0e-6
      assert geometry.z == 2.0
    end

    test "places nothing past 90° off a fisheye's axis" do
      calibration =
        %{
          camera_calibration("equidistant", [200.0, 0.0, 400.0, 0.0, 200.0, 400.0], [])
          | width: 800,
            height: 800
        }

      # 100° to the right of the axis.
      u = 400.0 + 200.0 * 100 * :math.pi() / 180

      assert Fusion.unproject_camera(box(u - 5, 395, u + 5, 405), 2.0, calibration) == nil
    end

    test "measures the box between the points its edges see through the lens's distortion" do
      calibration =
        camera_calibration(
          "plumb_bob",
          [600.0, 0.0, 330.0, 0.0, 590.0, 245.0],
          [-0.25, 0.08, 0.0, 0.0, 0.01]
        )

      # Radial distortion only: the edges' middles are these points' pixels.
      {left, _} = opencv_pixel({-0.5, 0.0, 2.0}, calibration)
      {right, _} = opencv_pixel({0.5, 0.0, 2.0}, calibration)
      {_, top} = opencv_pixel({0.0, -0.4, 2.0}, calibration)
      {_, bottom} = opencv_pixel({0.0, 0.4, 2.0}, calibration)

      geometry = Fusion.unproject_camera(box(left, top, right, bottom), 2.0, calibration)

      assert_in_delta geometry.width, 1.0, 1.0e-6
      assert_in_delta geometry.height, 0.8, 1.0e-6
      # The camera matrix alone puts the barrel-shrunk edges closer together.
      refute_in_delta (right - left) * 2.0 / 600.0, 1.0, 0.01
    end

    test "places nothing where a ray it needs is past the lens's fold" do
      calibration =
        camera_calibration("plumb_bob", [300.0, 0.0, 320.0, 0.0, 300.0, 240.0], [-0.5])

      assert Fusion.unproject_camera(box(400, 200, 639, 280), 2.0, calibration) == nil
      assert %{z: 2.0} = Fusion.unproject_camera(box(400, 200, 470, 280), 2.0, calibration)
    end

    test "takes a lens built once in place of the calibration" do
      calibration =
        camera_calibration(
          "plumb_bob",
          [600.0, 0.0, 330.0, 0.0, 590.0, 245.0],
          [-0.25, 0.08, 1.0e-3, -1.5e-3, 0.01]
        )

      box = box(100, 80, 180, 200)

      assert Fusion.unproject_camera(
               box,
               2.0,
               VisionCore.Detection.Reprojection.lens(calibration)
             ) ==
               Fusion.unproject_camera(box, 2.0, calibration)
    end

    defp camera_calibration(model, camera_matrix, coefficients) do
      %CameraCalibration{
        width: 640,
        height: 480,
        distortion_model: model,
        distortion_coefficients: coefficients,
        camera_matrix: camera_matrix ++ [0.0, 0.0, 1.0]
      }
    end

    defp opencv_pixel({x, y, z}, calibration) do
      {pixels, _jacobian} =
        Evision.projectPoints(
          Evision.Mat.from_nx_2d(Nx.tensor([[x, y, z]], type: :f64)),
          Evision.Mat.from_nx(Nx.tensor([0.0, 0.0, 0.0], type: :f64)),
          Evision.Mat.from_nx(Nx.tensor([0.0, 0.0, 0.0], type: :f64)),
          matrix(calibration.camera_matrix),
          Evision.Mat.from_nx_2d(Nx.tensor([calibration.distortion_coefficients], type: :f64))
        )

      [[[u, v]]] = pixels |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.to_list()
      {u, v}
    end
  end

  defp projected_points(points) do
    binary =
      for {u, v, z} <- points,
          into: <<>>,
          do: <<u::float-32-native, v::float-32-native, z::float-32-native>>

    %{count: length(points), points: binary}
  end

  # A value as the 32-bit float the projected points carry.
  defp f32(value) do
    <<rounded::float-32-native>> = <<value::float-32-native>>
    rounded
  end

  defp matrix(values),
    do: values |> Nx.tensor(type: :f64) |> Nx.reshape({3, 3}) |> Evision.Mat.from_nx_2d()
end
