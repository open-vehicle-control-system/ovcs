defmodule RosBridge.Perception.FusionTest do
  use ExUnit.Case, async: true

  alias RosBridge.Perception.Fusion

  # A depth map built by hand so the expected answer is arithmetic
  # rather than a recording: `values` is a list of rows in metres.
  defp depth_mat(rows) do
    height = length(rows)
    width = rows |> hd() |> length()

    binary =
      rows
      |> List.flatten()
      |> Enum.reduce(<<>>, fn value, acc -> acc <> <<value::little-float-32>> end)

    Evision.Mat.from_binary(binary, {:f, 32}, height, width, 1)
  end

  defp box(x0, y0, x1, y1), do: %{x0: x0 / 1.0, y0: y0 / 1.0, x1: x1 / 1.0, y1: y1 / 1.0}

  describe "median_depth/3" do
    test "takes the median over the central fraction of the box" do
      # 8x8 of 5.0 m with a 4x4 block of 2.0 m in the middle. With
      # fraction 0.5 the sample window is exactly that middle block.
      rows =
        for y <- 0..7 do
          for x <- 0..7 do
            if x in 2..5 and y in 2..5, do: 2.0, else: 5.0
          end
        end

      assert Fusion.median_depth(depth_mat(rows), box(0, 0, 8, 8), 0.5) == 2.0
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

      assert Fusion.median_depth(depth_mat(rows), box(0, 0, 8, 8), 1.0) == 5.0
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

      assert Fusion.median_depth(depth_mat(rows), box(0, 0, 4, 4), 1.0) == 2.0
    end

    test "returns nil when nothing inside the box was measured" do
      rows = for _ <- 0..3, do: for(_ <- 0..3, do: 0.0)
      assert Fusion.median_depth(depth_mat(rows), box(0, 0, 4, 4), 1.0) == nil
    end

    test "clamps a box that runs off the edge of the frame" do
      rows = for _ <- 0..3, do: for(_ <- 0..3, do: 3.0)
      # A person cut off at the right edge: x1 beyond the width.
      assert Fusion.median_depth(depth_mat(rows), box(2, 0, 40, 4), 1.0) == 3.0
    end

    test "averages the two middle values for an even sample count" do
      rows = [[1.0, 2.0], [3.0, 4.0]]
      assert Fusion.median_depth(depth_mat(rows), box(0, 0, 2, 2), 1.0) == 2.5
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

  describe "outline/2" do
    test "produces LINE_LIST pairs that close the rectangle" do
      points = Fusion.outline(box(10, 20, 110, 220), 1)

      # 4 edges x 2 endpoints.
      assert length(points) == 8

      assert points == [
               {10.0, 20.0},
               {110.0, 20.0},
               {110.0, 20.0},
               {110.0, 220.0},
               {110.0, 220.0},
               {10.0, 220.0},
               {10.0, 220.0},
               {10.0, 20.0}
             ]
    end

    test "subdividing keeps the pair count at 8 x segments" do
      assert length(Fusion.outline(box(0, 0, 100, 100), 4)) == 32
    end

    test "subdivision points lie on the edge" do
      [_a, b | _] = Fusion.outline(box(0, 0, 100, 0), 2)
      # First edge halved: the midpoint of (0,0)..(100,0).
      assert b == {50.0, 0.0}
    end
  end

  describe "remap/4" do
    # A 2x2 CV_16SC2 map, interleaved int16 x, y per rectified pixel.
    defp map_binary(pairs) do
      Enum.reduce(pairs, <<>>, fn {x, y}, acc ->
        acc <> <<x::little-signed-16, y::little-signed-16>>
      end)
    end

    test "reads the raw pixel for a rectified coordinate" do
      # Row-major: (0,0) (1,0) / (0,1) (1,1)
      binary = map_binary([{10, 20}, {11, 21}, {12, 22}, {13, 23}])

      assert Fusion.remap(binary, 2, 2, {0, 0}) == {10.0, 20.0}
      assert Fusion.remap(binary, 2, 2, {1, 0}) == {11.0, 21.0}
      assert Fusion.remap(binary, 2, 2, {0, 1}) == {12.0, 22.0}
      assert Fusion.remap(binary, 2, 2, {1, 1}) == {13.0, 23.0}
    end

    test "clamps a coordinate outside the frame rather than reading past the map" do
      binary = map_binary([{10, 20}, {11, 21}, {12, 22}, {13, 23}])

      assert Fusion.remap(binary, 2, 2, {99, 99}) == {13.0, 23.0}
      assert Fusion.remap(binary, 2, 2, {-5, -5}) == {10.0, 20.0}
    end

    test "rounds a fractional coordinate to the nearest pixel" do
      binary = map_binary([{10, 20}, {11, 21}, {12, 22}, {13, 23}])
      assert Fusion.remap(binary, 2, 2, {0.6, 0.4}) == {11.0, 21.0}
    end

    test "returns nil when the map is too short for the coordinate" do
      assert Fusion.remap(<<0, 0, 0, 0>>, 8, 8, {7, 7}) == nil
    end
  end
end
