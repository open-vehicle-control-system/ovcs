defmodule Perception.LanePolygon do
  def new(lines, min_y, max_y, min_x, max_x) do
    lines |> to_points |> to_polygon(min_y, max_y, min_x, max_x)
  end

  defp to_points(lines) do
    points = %{
      left_line_x: [],
      left_line_y: [],
      right_line_x: [],
      right_line_y: []
    }

    Enum.reduce(lines, points, fn line, points ->
      if line.boundary == :left do
        %{ points |
          left_line_x: [ [line.x1, line.x2] | points.left_line_x ],
          left_line_y: [ [line.y1, line.y2] | points.left_line_y ]
        }
      else
        %{ points |
          right_line_x: [ [line.x1, line.x2] | points.right_line_x ],
          right_line_y: [ [line.y1, line.y2] | points.right_line_y ]
        }
      end
    end)
  end

  defp to_polygon(points, min_y, max_y, _min_x, _max_x) do
    if points.left_line_x == [] or points.right_line_x == [] or points.left_line_y == [] or points.right_line_y == [] do
      []
    else
      left_line_xs     = points.left_line_x |> to_flat_tensor
      left_line_ys     = points.left_line_y |> to_flat_tensor
      right_line_xs    = points.right_line_x |> to_flat_tensor
      right_line_ys    = points.right_line_y |> to_flat_tensor
      left_regression  = Scholar.Linear.LinearRegression.fit(left_line_xs, left_line_ys)
      right_regression = Scholar.Linear.LinearRegression.fit(right_line_xs, right_line_ys)

      left_start_x  = x_from_y_and_regression(max_y, left_regression) |> to_valid_coordinate
      left_end_x    = x_from_y_and_regression(min_y, left_regression) |> to_valid_coordinate
      right_start_x = x_from_y_and_regression(max_y, right_regression) |> to_valid_coordinate
      right_end_x   = x_from_y_and_regression(min_y, right_regression) |> to_valid_coordinate

      if right_end_x <= left_end_x do
        [[left_start_x, max_y],
        [left_end_x, min_y],
        [left_end_x, min_y],
        [right_start_x, max_y]]
      else
        [[left_start_x, max_y],
        [left_end_x, min_y],
        [right_end_x, min_y],
        [right_start_x, max_y]]
      end
    end
  end

  defp to_flat_tensor(points) do
    Nx.tensor(Enum.map(List.flatten(points), fn x -> [x] end))
  end

  defp x_from_y_and_regression(y, regression) do
    # y = (coefficient)x + intercept
    # x = (y - intercept)/coefficient
    (Nx.subtract(y, regression.intercept) |> Nx.divide(regression.coefficients[0]))[0]
    end

  defp to_valid_coordinate(value) do
    trunc(Nx.to_number(Nx.ceil(value)))
  end
end
