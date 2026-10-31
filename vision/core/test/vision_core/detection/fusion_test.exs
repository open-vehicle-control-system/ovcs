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
          |> then(fn p -> Enum.map([0, 1, 2, 4, 5, 6, 8, 9, 10], &Enum.at(p, &1)) end)
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

    defp matrix(values),
      do: values |> Nx.tensor(type: :f64) |> Nx.reshape({3, 3}) |> Evision.Mat.from_nx_2d()
  end
end
