defmodule VisionCore.CameraDepth.ReprojectionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, Pose}
  alias VisionCore.CameraDepth.Reprojection
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  # The rectified left intrinsics of the test pairs.
  @left_fx 50.0
  @left_centre {32.0, 24.0}

  # A rotation of 0.23 rad about an oblique axis and a translation on every axis, so a
  # transposed rotation or a sign error moves the points.
  @rotation_vector [0.1, -0.2, 0.05]
  @translation [0.12, -0.03, 0.05]

  describe "project/4" do
    test "projects every stride-th measured depth pixel as OpenCV's projectPoints does" do
      calibration =
        calibration("plumb_bob", {600.0, 590.0, 330.0, 245.0}, [
          -0.25,
          0.08,
          1.0e-3,
          -1.5e-3,
          0.01
        ])

      pair = pair(sloped_depth_mm(64, 48))

      expected =
        pair
        |> left_points(2)
        |> opencv_projection(&opencv_plumb_bob(&1, calibration))
        |> inside(calibration)

      assert_points(Reprojection.project(pair, calibration, oblique_pose(), 2), expected)
      # Some points land outside the image, which the projection leaves out.
      assert length(expected) < length(left_points(pair, 2))
    end

    test "projects with an equidistant lens as OpenCV's fisheye projectPoints does" do
      calibration =
        calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 4.0e-3, -1.0e-3])

      pair = pair(sloped_depth_mm(64, 48))

      expected =
        pair
        |> left_points(2)
        |> opencv_projection(&opencv_fisheye(&1, calibration))
        |> inside(calibration)

      assert_points(Reprojection.project(pair, calibration, oblique_pose(), 2), expected)
    end

    test "takes every pixel at stride 1 and every second one by default" do
      calibration = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])
      pair = pair(sloped_depth_mm(64, 48))

      identity = %Pose{
        rotation: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        translation: [0.0, 0.0, 0.0]
      }

      assert size(Reprojection.project(pair, calibration, identity, 1)) ==
               length(left_points(pair, 1))

      assert Reprojection.project(pair, calibration, identity) ==
               Reprojection.project(pair, calibration, identity, 2)
    end

    test "never projects a point behind a plumb_bob camera, which its formula maps into the image" do
      calibration = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])
      # One point on the left camera's axis, 3 m ahead: behind a camera turned half a turn.
      pair = pair(single_depth_mm(3000))

      assert empty?(Reprojection.project(pair, calibration, turned(:math.pi()), 1))
      assert size(Reprojection.project(pair, calibration, turned(0.0), 1)) == 1
    end

    test "leaves out a plumb_bob point past where its distortion folds back into the image" do
      # r (1 - 0.5 r²) grows up to r = 0.82 and falls after: r = tan 50° = 1.19 lands 0.34
      # from the centre, inside the image, where a point 20° off-axis lands too.
      calibration =
        calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [-0.5, 0.0, 0.0, 0.0, 0.0])

      pair = pair(single_depth_mm(3000))

      assert empty?(Reprojection.project(pair, calibration, turned(degrees(50)), 1))
      assert size(Reprojection.project(pair, calibration, turned(degrees(30)), 1)) == 1
    end

    test "projects a fisheye point past 90° off-axis inside the lens's field" do
      # An equidistant lens: 200 px per radian, so 100° lands 349 px right of the centre.
      calibration =
        calibration("equidistant", {200.0, 200.0, 400.0, 400.0}, [0.0, 0.0, 0.0, 0.0], {800, 800})

      pair = pair(single_depth_mm(3000))

      assert_points(Reprojection.project(pair, calibration, turned(degrees(100)), 1), [
        {400.0 + 200.0 * degrees(100), 400.0, 3.0 * :math.cos(degrees(100))}
      ])
    end

    test "never projects a fisheye point behind the lens's field" do
      calibration =
        calibration("equidistant", {200.0, 200.0, 400.0, 400.0}, [0.0, 0.0, 0.0, 0.0], {800, 800})

      pair = pair(single_depth_mm(3000))

      # 170° lands 593 px right of the centre, past the image's right edge.
      assert empty?(Reprojection.project(pair, calibration, turned(degrees(170)), 1))
      assert empty?(Reprojection.project(pair, calibration, turned(:math.pi()), 1))
    end

    test "leaves out a fisheye point past where its distortion folds back into the image" do
      # θ (1 - 0.1 θ²) grows up to θ = 1.83 rad and falls after: θ = 2.5 rad lands 0.94 rad
      # from the centre, inside the image, where θ = 1.05 rad lands too.
      calibration =
        calibration(
          "equidistant",
          {200.0, 200.0, 400.0, 400.0},
          [-0.1, 0.0, 0.0, 0.0],
          {800, 800}
        )

      pair = pair(single_depth_mm(3000))

      assert empty?(Reprojection.project(pair, calibration, turned(2.5), 1))
      assert size(Reprojection.project(pair, calibration, turned(degrees(100)), 1)) == 1
    end

    test "projects with a calibration of another size once scaled to the camera's frame" do
      calibration =
        calibration(
          "plumb_bob",
          {800.0, 780.0, 660.0, 490.0},
          [-0.25, 0.08, 1.0e-3, -1.5e-3, 0.01],
          {1280, 960}
        )

      pair = pair(sloped_depth_mm(64, 48))
      native = Reprojection.project(pair, calibration, oblique_pose(), 2)

      scaled =
        Reprojection.project(
          pair,
          CameraCalibration.scale_to(calibration, 640, 480),
          oblique_pose(),
          2
        )

      halved = Enum.map(triples(native), fn {u, v, z} -> {u / 2, v / 2, z} end)
      assert_points(scaled, halved)
    end

    test "applies the camera matrix's skew, which OpenCV's projectPoints leaves out" do
      calibration = skewed_calibration()
      pair = pair(single_depth_mm(3000))
      lowered = %Pose{turned(0.0) | translation: [0.0, 0.5, 0.0]}

      # The point is at (0, 0.5, 3): y = 1/6 on the plane 1 m ahead.
      assert_points(Reprojection.project(pair, calibration, lowered, 1), [
        {320.0 + 30.0 / 6, 240.0 + 400.0 / 6, 3.0}
      ])
    end

    test "refuses a distortion model it does not implement" do
      calibration = %{
        calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])
        | distortion_model: "rational_polynomial"
      }

      assert_raise ArgumentError, ~r/rational_polynomial/, fn ->
        Reprojection.project(pair(single_depth_mm(3000)), calibration, turned(0.0), 1)
      end
    end
  end

  describe "project_with_origin/4" do
    test "gives each projected point's pixel with its position in the left optical frame" do
      calibration =
        calibration("plumb_bob", {600.0, 590.0, 330.0, 245.0}, [
          -0.25,
          0.08,
          1.0e-3,
          -1.5e-3,
          0.01
        ])

      pair = pair(sloped_depth_mm(64, 48))
      left = left_points(pair, 2)

      expected =
        left
        |> opencv_plumb_bob(calibration)
        |> Enum.zip_with(left, fn {u, v}, {x, y, z} -> {u, v, x, y, z} end)
        |> Enum.filter(fn {u, v, _x, _y, _z} -> u >= 0 and u < 640 and v >= 0 and v < 480 end)

      projection = Reprojection.project_with_origin(pair, calibration, oblique_pose(), 2)

      projected =
        for <<u::float-32-native, v::float-32-native, x::float-32-native, y::float-32-native,
              z::float-32-native <- projection.points>>,
            do: {u, v, x, y, z}

      assert projection.count == length(expected)
      assert length(expected) < length(left)

      Enum.zip_with(projected, expected, fn {u, v, x, y, z}, {eu, ev, ex, ey, ez} ->
        assert_in_delta u, eu, 1.0e-3
        assert_in_delta v, ev, 1.0e-3

        for {value, wanted} <- [{x, ex}, {y, ey}, {z, ez}],
            do: assert_in_delta(value, wanted, 1.0e-5)
      end)
    end

    test "projects the same points as project/4" do
      calibration = calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 0.0])
      pair = pair(sloped_depth_mm(64, 48))
      with_origin = Reprojection.project_with_origin(pair, calibration, oblique_pose(), 3)

      pixels =
        for <<u::float-32-native, v::float-32-native,
              _origin::binary-size(12) <-
                with_origin.points>>,
            do: {u, v}

      assert pixels ==
               for(
                 {u, v, _z} <- triples(Reprojection.project(pair, calibration, oblique_pose(), 3)),
                 do: {u, v}
               )
    end
  end

  describe "check/1" do
    test "accepts plumb_bob with up to 5 coefficients and equidistant with up to 4" do
      for {model, coefficients} <- [
            {"plumb_bob", []},
            {"plumb_bob", [-0.25, 0.08, 1.0e-3, -1.5e-3, 0.01]},
            {"equidistant", [0.03, -0.01, 4.0e-3, -1.0e-3]}
          ] do
        assert Reprojection.check(calibration(model, {400.0, 400.0, 320.0, 240.0}, coefficients)) ==
                 :ok
      end
    end

    test "refuses what it cannot project with" do
      valid = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])

      for invalid <- [
            %{valid | distortion_model: "rational_polynomial"},
            %{valid | distortion_coefficients: [0.1, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0]},
            %{
              valid
              | distortion_model: "equidistant",
                distortion_coefficients: [0.1, 0.0, 0.0, 0.0, 0.0]
            },
            %{valid | camera_matrix: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]},
            %{valid | width: 0}
          ] do
        assert {:error, message} = Reprojection.check(invalid)
        assert is_binary(message)
      end
    end
  end

  describe "check_lens/1" do
    test "accepts a calibration without an image size, and refuses a lens it cannot project with" do
      valid = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])

      assert Reprojection.check_lens(%{valid | width: 0, height: 0}) == :ok

      for invalid <- [
            %{valid | distortion_model: "rational_polynomial"},
            %{valid | distortion_coefficients: [0.1, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0]},
            %{valid | camera_matrix: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]}
          ] do
        assert {:error, message} = Reprojection.check_lens(invalid)
        assert is_binary(message)
      end
    end
  end

  describe "ray/2" do
    test "gives the direction of the point a plumb_bob pixel sees, as OpenCV projects it" do
      calibration =
        calibration("plumb_bob", {400.0, 390.0, 330.0, 245.0}, [
          -0.25,
          0.08,
          1.0e-3,
          -1.5e-3,
          0.01
        ])

      for point <- [{0.4, -0.3, 1.0}, {-0.6, 0.5, 2.0}, {0.0, 0.0, 3.0}] do
        [pixel] = opencv_plumb_bob([point], calibration, identity_vectors())
        assert_direction(Reprojection.ray(calibration, pixel), point)
      end
    end

    test "gives the direction of the point a fisheye pixel sees, as OpenCV projects it" do
      calibration =
        calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 4.0e-3, -1.0e-3])

      for point <- [{0.4, -0.3, 1.0}, {-1.5, 1.2, 1.0}, {0.0, 0.0, 3.0}] do
        [pixel] = opencv_fisheye([point], calibration, identity_vectors())
        assert_direction(Reprojection.ray(calibration, pixel), point)
      end
    end

    test "takes the camera matrix's skew out" do
      assert_direction(
        Reprojection.ray(skewed_calibration(), {320.0 + 30.0 / 6, 240.0 + 400.0 / 6}),
        {0.0, 0.5, 3.0}
      )
    end

    test "gives a fisheye direction past 90° off-axis" do
      calibration =
        calibration("equidistant", {200.0, 200.0, 400.0, 400.0}, [0.0, 0.0, 0.0, 0.0], {800, 800})

      angle = degrees(100)

      assert_direction(
        Reprojection.ray(calibration, {400.0 + 200.0 * angle, 400.0}),
        {:math.sin(angle), 0.0, :math.cos(angle)}
      )
    end
  end

  describe "ray/2 against OpenCV's undistortion" do
    @pixels [{100.0, 80.0}, {600.0, 50.0}, {330.0, 470.0}]

    test "undistorts a plumb_bob pixel as undistortPoints does, iterated to convergence" do
      calibration =
        calibration("plumb_bob", {400.0, 390.0, 330.0, 245.0}, [
          -0.25,
          0.08,
          1.0e-3,
          -1.5e-3,
          0.01
        ])

      identity = matrix([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0])

      normalised =
        Evision.undistortPointsIter(
          pixel_points(@pixels),
          matrix(calibration.camera_matrix),
          coefficients(calibration.distortion_coefficients, 5),
          identity,
          identity,
          {3, 100, 1.0e-14}
        )

      assert_rays(calibration, normalised)
    end

    test "undistorts an equidistant pixel as fisheye undistortPoints does" do
      calibration =
        calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 4.0e-3, -1.0e-3])

      normalised =
        Evision.FishEye.undistortPoints(
          pixel_points(@pixels),
          matrix(calibration.camera_matrix),
          coefficients(calibration.distortion_coefficients, 4)
        )

      assert_rays(calibration, normalised)
    end

    defp pixel_points(pixels) do
      pixels
      |> Enum.map(fn {u, v} -> [[u, v]] end)
      |> Nx.tensor(type: :f64)
      |> Evision.Mat.from_nx()
      |> Evision.Mat.last_dim_as_channel()
    end

    defp assert_rays(calibration, normalised) do
      expected = pixel_list(normalised)

      Enum.zip_with(Reprojection.rays(calibration, @pixels), expected, fn {x, y, z},
                                                                          {expected_x, expected_y} ->
        assert_in_delta x / z, expected_x, 1.0e-7
        assert_in_delta y / z, expected_y, 1.0e-7
      end)
    end
  end

  describe "rays/2" do
    test "gives each pixel's ray/2" do
      calibration =
        calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 4.0e-3, -1.0e-3])

      pixels = [{10.0, 20.0}, {320.0, 240.0}, {600.0, 400.0}]

      assert Reprojection.rays(calibration, pixels) ==
               Enum.map(pixels, &Reprojection.ray(calibration, &1))
    end
  end

  describe "a pixel past the lens's fold" do
    # r (1 - 0.5 r²) peaks at 0.544, 163 px from the centre at f = 300.
    defp folded_plumb_bob,
      do: calibration("plumb_bob", {300.0, 300.0, 320.0, 240.0}, [-0.5, 0.0, 0.0, 0.0, 0.0])

    # θ (1 - 0.1 θ²) peaks at 1.217 rad, 243 px from the centre at f = 200.
    defp folded_fisheye,
      do:
        calibration(
          "equidistant",
          {200.0, 200.0, 400.0, 400.0},
          [-0.1, 0.0, 0.0, 0.0],
          {800, 800}
        )

    test "has no plumb_bob ray, where one inside the fold has its own" do
      assert Reprojection.ray(folded_plumb_bob(), {639.0, 240.0}) == nil
      assert Reprojection.ray(folded_plumb_bob(), {500.0, 240.0}) == nil

      # 150 px right: x (1 - 0.5 x²) = 0.5 at x = 0.618.
      {x, y, z} = Reprojection.ray(folded_plumb_bob(), {470.0, 240.0})
      assert_in_delta x / z * (1 - 0.5 * (x / z) ** 2), 0.5, 1.0e-9
      assert_in_delta y, 0.0, 1.0e-12
    end

    test "has no plumb_bob ray where the undistortion settles past the fold" do
      # r (1 - 0.5 r² + 0.1 r⁴) folds at r = 1, falls to r = 1.41 and grows again:
      # 0.62 is reached again at r = 1.64, where the iteration converges.
      calibration =
        calibration("plumb_bob", {300.0, 300.0, 320.0, 240.0}, [-0.5, 0.1, 0.0, 0.0, 0.0])

      assert Reprojection.ray(calibration, {320.0 + 0.62 * 300, 240.0}) == nil
    end

    test "has no plumb_bob ray where the undistortion does not converge" do
      # r (1 - 0.3 r² + 0.02 r⁴) peaks at 0.734 at r = 1.14: nothing lands at 0.8, and
      # the iteration wanders inside the fold.
      calibration =
        calibration("plumb_bob", {300.0, 300.0, 320.0, 240.0}, [-0.3, 0.02, 0.0, 0.0, 0.0])

      assert Reprojection.ray(calibration, {320.0 + 0.8 * 300, 240.0}) == nil
      assert {_x, _y, _z} = Reprojection.ray(calibration, {320.0 + 0.7 * 300, 240.0})
    end

    test "has no fisheye ray, where one inside the fold has its own" do
      assert Reprojection.ray(folded_fisheye(), {700.0, 400.0}) == nil
      assert Reprojection.ray(folded_fisheye(), {799.0, 400.0}) == nil

      # 200 px right: θ (1 - 0.1 θ²) = 1.0 rad.
      {x, _y, z} = Reprojection.ray(folded_fisheye(), {600.0, 400.0})
      angle = :math.atan2(x, z)
      assert_in_delta angle * (1 - 0.1 * angle * angle), 1.0, 1.0e-9
    end

    test "has no ray in rays/2 and no bearing" do
      assert [{_x, _y, _z}, nil] =
               Reprojection.rays(folded_plumb_bob(), [{470.0, 240.0}, {639.0, 240.0}])

      assert Reprojection.bearing(folded_plumb_bob(), {639.0, 240.0}) == nil
      assert Reprojection.bearing(folded_fisheye(), {799.0, 400.0}) == nil
    end
  end

  describe "lens/1" do
    test "projects, and gives rays and bearings, as its calibration does" do
      calibration =
        calibration("equidistant", {250.0, 245.0, 320.0, 240.0}, [0.03, -0.01, 4.0e-3, -1.0e-3])

      lens = Reprojection.lens(calibration)
      pair = pair(sloped_depth_mm(64, 48))
      pixels = [{10.0, 20.0}, {600.0, 400.0}]

      assert Reprojection.project(pair, lens, oblique_pose(), 2) ==
               Reprojection.project(pair, calibration, oblique_pose(), 2)

      assert Reprojection.rays(lens, pixels) == Reprojection.rays(calibration, pixels)
      assert Reprojection.ray(lens, {10.0, 20.0}) == Reprojection.ray(calibration, {10.0, 20.0})

      assert Reprojection.bearing(lens, {10.0, 20.0}) ==
               Reprojection.bearing(calibration, {10.0, 20.0})
    end

    test "refuses a calibration check/1 refuses" do
      calibration = %{
        calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])
        | width: 0
      }

      assert_raise ArgumentError, ~r/image size/, fn -> Reprojection.lens(calibration) end
    end
  end

  describe "bearing/2" do
    test "is positive to the right and up, in radians" do
      calibration = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])

      {azimuth, elevation} = Reprojection.bearing(calibration, {720.0, 40.0})

      assert_in_delta azimuth, :math.atan(1.0), 1.0e-9
      assert_in_delta elevation, :math.atan2(0.5, :math.sqrt(2.0)), 1.0e-9
    end
  end

  defp skewed_calibration do
    calibration = calibration("plumb_bob", {400.0, 400.0, 320.0, 240.0}, [])
    %{calibration | camera_matrix: [400.0, 30.0, 320.0, 0.0, 400.0, 240.0, 0.0, 0.0, 1.0]}
  end

  defp calibration(model, {fx, fy, cx, cy}, coefficients, {width, height} \\ {640, 480}) do
    %CameraCalibration{
      width: width,
      height: height,
      distortion_model: model,
      distortion_coefficients: coefficients,
      camera_matrix: [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  # A depth map of `rows` lists of millimetres, as the stereo pipeline's.
  defp pair(rows) do
    width = rows |> hd() |> length()
    height = length(rows)
    depth = for millimetres <- List.flatten(rows), into: <<>>, do: <<millimetres::little-16>>
    frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      depth: depth,
      geometry: %{
        width: width,
        height: height,
        focal_length_px: @left_fx,
        principal_point: @left_centre
      }
    }
  end

  # 2 to 5 m, with every seventh pixel unmeasured.
  defp sloped_depth_mm(width, height) do
    for v <- 0..(height - 1) do
      for u <- 0..(width - 1), do: if(rem(u + v, 7) == 0, do: 0, else: 2000 + 37 * u + 23 * v)
    end
  end

  # One measured pixel, at the left camera's principal point.
  defp single_depth_mm(millimetres) do
    {cx, cy} = @left_centre

    for v <- 0..47 do
      for u <- 0..63, do: if({u, v} == {trunc(cx), trunc(cy)}, do: millimetres, else: 0)
    end
  end

  # The measured pixels' points in the rectified left frame, in metres, row by row.
  defp left_points(%Pair{depth: depth, geometry: geometry}, stride) do
    {cx, cy} = geometry.principal_point

    for v <- 0..(geometry.height - 1)//stride,
        u <- 0..(geometry.width - 1)//stride,
        <<millimetres::little-16>> = binary_part(depth, (v * geometry.width + u) * 2, 2),
        millimetres > 0 do
      z = millimetres / 1000
      {(u - cx) * z / geometry.focal_length_px, (v - cy) * z / geometry.focal_length_px, z}
    end
  end

  defp oblique_pose do
    {rotation, _jacobian} =
      Evision.rodrigues(Evision.Mat.from_nx(Nx.tensor(@rotation_vector, type: :f64)))

    %Pose{
      rotation: rotation |> Evision.Mat.to_nx(Nx.BinaryBackend) |> Nx.to_flat_list(),
      translation: @translation
    }
  end

  # The camera turned `angle` about its y axis: the left camera's axis `angle` to its right.
  defp turned(angle) do
    {sine, cosine} = {:math.sin(angle), :math.cos(angle)}

    %Pose{
      rotation: [cosine, 0.0, sine, 0.0, 1.0, 0.0, -sine, 0.0, cosine],
      translation: [0.0, 0.0, 0.0]
    }
  end

  defp degrees(angle), do: angle * :math.pi() / 180

  # Each point as {u, v, z}: OpenCV's pixel, and z in the camera's frame from the pose.
  defp opencv_projection(points, project) do
    pose = oblique_pose()

    points
    |> project.()
    |> Enum.zip_with(points, fn {u, v}, point -> {u, v, camera_z(pose, point)} end)
  end

  defp camera_z(
         %Pose{rotation: [_, _, _, _, _, _, r20, r21, r22], translation: [_, _, tz]},
         {x, y, z}
       ),
       do: r20 * x + r21 * y + r22 * z + tz

  defp identity_vectors, do: {[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]}

  defp opencv_plumb_bob(
         points,
         calibration,
         {rotation_vector, translation} \\ {@rotation_vector, @translation}
       ) do
    {pixels, _jacobian} =
      Evision.projectPoints(
        points |> Enum.map(&Tuple.to_list/1) |> Nx.tensor(type: :f64) |> Evision.Mat.from_nx_2d(),
        vector(rotation_vector),
        vector(translation),
        matrix(calibration.camera_matrix),
        coefficients(calibration.distortion_coefficients, 5)
      )

    pixel_list(pixels)
  end

  defp opencv_fisheye(
         points,
         calibration,
         {rotation_vector, translation} \\ {@rotation_vector, @translation}
       ) do
    {pixels, _jacobian} =
      Evision.FishEye.projectPoints(
        points
        |> Enum.map(&[Tuple.to_list(&1)])
        |> Nx.tensor(type: :f64)
        |> Evision.Mat.from_nx()
        |> Evision.Mat.last_dim_as_channel(),
        vector(rotation_vector),
        vector(translation),
        matrix(calibration.camera_matrix),
        coefficients(calibration.distortion_coefficients, 4)
      )

    pixel_list(pixels)
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

  defp inside(points, %CameraCalibration{width: width, height: height}),
    do: Enum.filter(points, fn {u, v, _z} -> u >= 0 and u < width and v >= 0 and v < height end)

  defp triples(%{count: count, points: points}) do
    triples =
      for <<u::float-32-native, v::float-32-native, z::float-32-native <- points>>, do: {u, v, z}

    assert length(triples) == count
    triples
  end

  defp assert_points(projection, expected) do
    projected = triples(projection)
    assert length(projected) == length(expected)

    Enum.zip_with(projected, expected, fn {u, v, z}, {expected_u, expected_v, expected_z} ->
      assert_in_delta u, expected_u, 1.0e-3
      assert_in_delta v, expected_v, 1.0e-3
      assert_in_delta z, expected_z, 1.0e-5
    end)
  end

  defp assert_direction({x, y, z}, {expected_x, expected_y, expected_z}) do
    length = :math.sqrt(expected_x ** 2 + expected_y ** 2 + expected_z ** 2)
    assert_in_delta :math.sqrt(x * x + y * y + z * z), 1.0, 1.0e-9
    assert_in_delta x, expected_x / length, 1.0e-6
    assert_in_delta y, expected_y / length, 1.0e-6
    assert_in_delta z, expected_z / length, 1.0e-6
  end

  defp size(projection), do: projection |> triples() |> length()
  defp empty?(projection), do: size(projection) == 0
end
