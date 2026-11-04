defmodule VisionCore.Calibration.CoverageTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.{Board, Coverage}

  @board %Board{columns: 8, rows: 6, square_m: 0.025}
  @image {640, 480}

  # 8 x 6 grid spanning grid_width x grid_height from {left, top}, each row shifted `shear` px more than the last.
  defp grid(left, top, grid_width, grid_height, shear \\ 0.0) do
    for row <- 0..5, column <- 0..7 do
      {left + column * grid_width / 7 + row * shear, top + row * grid_height / 5}
    end
  end

  defp sample(x, size \\ 0.3, skew \\ 0.0, y \\ 0.5), do: %{x: x, y: y, size: size, skew: skew}

  describe "parameters/3" do
    test "a centred axis-aligned grid filling a quarter of the image" do
      params = Coverage.parameters(grid(160, 120, 320, 240), @board, @image)

      assert_in_delta params.x, 0.5, 0.02
      assert_in_delta params.y, 0.5, 0.02
      assert_in_delta params.size, 0.5, 0.02
      assert_in_delta params.skew, 0.0, 0.02
    end

    test "a grid at the left edge has a small x" do
      assert Coverage.parameters(grid(0, 120, 320, 240), @board, @image).x < 0.2
    end

    test "a sheared grid has skew" do
      shear = 240 / 5 * :math.tan(30 * :math.pi() / 180)
      assert Coverage.parameters(grid(160, 120, 320, 240, shear), @board, @image).skew > 0.5
    end
  end

  describe "good_sample?/2" do
    test "accepts the first sample and refuses a duplicate" do
      p = sample(0.5)
      assert Coverage.good_sample?(p, [])
      refute Coverage.good_sample?(p, [p])
    end

    test "needs an L1 distance above 0.2 from every kept sample" do
      assert Coverage.good_sample?(sample(0.71), [sample(0.5)])
      refute Coverage.good_sample?(sample(0.69), [sample(0.5)])
    end
  end

  describe "progress/1" do
    test "x spanning 0.1..0.8 is complete" do
      assert Coverage.progress([sample(0.1), sample(0.8)]).x == 1.0
    end

    test "size is measured from 0" do
      progress = Coverage.progress([sample(0.5, 0.1), sample(0.5, 0.3)])
      assert_in_delta progress.size, 0.75, 1.0e-9
    end

    test "no samples is no progress" do
      assert Coverage.progress([]) == %{x: 0.0, y: 0.0, size: 0.0, skew: 0.0}
    end
  end

  describe "good_enough?/1" do
    test "40 samples suffice, 39 do not" do
      assert Coverage.good_enough?(List.duplicate(sample(0.5), 40))
      refute Coverage.good_enough?(List.duplicate(sample(0.5), 39))
    end

    test "five samples covering every axis suffice" do
      samples = [
        sample(0.1, 0.1, 0.0, 0.1),
        sample(0.8, 0.2, 0.2, 0.8),
        sample(0.5, 0.5, 0.6, 0.5),
        sample(0.3, 0.3, 0.3, 0.3),
        sample(0.6, 0.4, 0.1, 0.6)
      ]

      assert Coverage.good_enough?(samples)
    end

    test "no samples is not enough" do
      refute Coverage.good_enough?([])
    end
  end

  describe "Board" do
    test "refuses a square board" do
      assert {:error, _} = Board.new(8, 8, 0.025)
    end

    test "accepts a valid board" do
      assert {:ok, %Board{columns: 8, rows: 6, square_m: 0.025}} = Board.new(8, 6, 0.025)
    end

    test "object_points runs row by row at z = 0" do
      points = Board.object_points(%Board{columns: 3, rows: 2, square_m: 0.1})

      assert Enum.take(points, 4) == [
               {0.0, 0.0, 0.0},
               {0.1, 0.0, 0.0},
               {0.2, 0.0, 0.0},
               {0.0, 0.1, 0.0}
             ]

      assert length(points) == 6
    end
  end
end
