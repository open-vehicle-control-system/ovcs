defmodule VisionCore.ChessboardImage do
  @moduledoc """
  Renders a chessboard into a grey image for the calibration tests.

  The board has `columns + 1` by `rows + 1` squares of `square_px` pixels,
  on a white background with `margin` pixels around it.
  """

  alias VisionCore.Calibration.Board

  @type t :: %{
          grey: binary(),
          width: pos_integer(),
          height: pos_integer(),
          corners: [{float(), float()}]
        }

  @doc """
  Options: `:width` and `:height` (the frame, default 1280 x 720), `:square_px`
  (default 60), `:margin` (default 100, the board's top-left offset),
  `:rotate` (`true` turns the image 180 degrees) and `:warp` (a 3 x 3
  perspective matrix as nested lists, applied to the rendered image).

  `:corners` holds the inner corners in the rendered image, row by row, with
  the top-left pixel centre at (0, 0).
  """
  @spec render(Board.t(), keyword()) :: t()
  def render(%Board{columns: columns, rows: rows}, options \\ []) do
    width = Keyword.get(options, :width, 1280)
    height = Keyword.get(options, :height, 720)
    square = Keyword.get(options, :square_px, 60)
    margin = Keyword.get(options, :margin, 100)

    pixels =
      for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
        <<pixel(x - margin, y - margin, square, columns + 1, rows + 1)>>
      end

    corners =
      for row <- 1..rows, column <- 1..columns do
        {margin + column * square - 0.5, margin + row * square - 0.5}
      end

    %{grey: pixels, width: width, height: height, corners: corners}
    |> maybe_rotate(Keyword.get(options, :rotate, false))
    |> maybe_warp(Keyword.get(options, :warp))
  end

  defp pixel(x, y, square, squares_x, squares_y) do
    column = Integer.floor_div(x, square)
    row = Integer.floor_div(y, square)

    if column in 0..(squares_x - 1) and row in 0..(squares_y - 1) and
         rem(column + row, 2) == 0,
       do: 0,
       else: 255
  end

  defp maybe_rotate(image, false), do: image

  defp maybe_rotate(%{grey: grey, width: width, height: height, corners: corners} = image, true) do
    rotated = grey |> Nx.from_binary(:u8) |> Nx.reverse() |> Nx.to_binary()

    %{
      image
      | grey: rotated,
        corners: Enum.map(corners, fn {x, y} -> {width - 1 - x, height - 1 - y} end)
    }
  end

  defp maybe_warp(image, nil), do: image

  defp maybe_warp(%{grey: grey, width: width, height: height, corners: corners} = image, matrix) do
    source = Evision.Mat.from_binary(grey, :u8, height, width, 1)
    homography = matrix |> Nx.tensor(type: :f64) |> Evision.Mat.from_nx_2d()

    warped =
      Evision.warpPerspective(source, homography, {width, height},
        borderMode: Evision.Constant.cv_BORDER_CONSTANT(),
        borderValue: {255, 255, 255, 255}
      )

    moved = Enum.map(corners, &project(&1, matrix))

    %{image | grey: Evision.Mat.to_binary(warped), corners: moved}
  end

  defp project({x, y}, [[a, b, c], [d, e, f], [g, h, i]]) do
    w = g * x + h * y + i
    {(a * x + b * y + c) / w, (d * x + e * y + f) / w}
  end
end
