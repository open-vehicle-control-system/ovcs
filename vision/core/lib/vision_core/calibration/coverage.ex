defmodule VisionCore.Calibration.Coverage do
  @moduledoc """
  Decides which chessboard views are worth keeping and when there are enough.

  A port of the sample-selection maths of ROS 2 `camera_calibration`
  (`calibrator.py`), keeping its defaults: a sample must lie more than 0.2 away
  (L1) from every kept one, the ranges are 0.7 for x and y, 0.4 for size and 0.5
  for skew, and calibration is good enough at 40 samples or once every axis is
  covered.

  A sample is a map `%{x, y, size, skew}`, each in 0..1: board position, apparent
  size, and skew, as returned by `parameters/3`.
  """

  alias VisionCore.Calibration.Board

  @min_distance 0.2
  @ranges %{x: 0.7, y: 0.7, size: 0.4, skew: 0.5}
  @enough_samples 40

  @type params :: %{x: float(), y: float(), size: float(), skew: float()}

  @doc """
  Position, size and skew of the board in an image of `{width, height}` pixels.

  `corners` are the detected inner corners as `{x, y}` pixel tuples, row by row.
  """
  @spec parameters([{number(), number()}], Board.t(), {pos_integer(), pos_integer()}) :: params()
  def parameters(corners, %Board{columns: columns}, {width, height}) do
    {up_left, up_right, down_right, down_left} = outside_corners(corners, columns)
    board_area = area(up_left, up_right, down_right, down_left)
    border = :math.sqrt(board_area)
    count = length(corners)
    mean_x = corners |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel./(count)
    mean_y = corners |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel./(count)

    %{
      x: clamp((mean_x - border / 2) / (width - border)),
      y: clamp((mean_y - border / 2) / (height - border)),
      size: :math.sqrt(board_area / (width * height)),
      skew: skew(up_left, up_right, down_right)
    }
  end

  @doc "Whether `params` is far enough from every sample in `kept`."
  @spec good_sample?(params(), [params()]) :: boolean()
  def good_sample?(params, kept), do: Enum.all?(kept, &(distance(params, &1) > @min_distance))

  @doc "Coverage of each axis in 0..1, from the spread of `samples`; size and skew count from 0."
  @spec progress([params()]) :: params()
  def progress([]), do: %{x: 0.0, y: 0.0, size: 0.0, skew: 0.0}

  def progress(samples) do
    Map.new(@ranges, fn {axis, range} ->
      values = Enum.map(samples, &Map.fetch!(&1, axis))
      minimum = if axis in [:size, :skew], do: 0.0, else: Enum.min(values)
      {axis, min(1.0, (Enum.max(values) - minimum) / range)}
    end)
  end

  @doc "Whether `samples` are enough to run the calibration."
  @spec good_enough?([params()]) :: boolean()
  def good_enough?(samples) do
    length(samples) >= @enough_samples or
      (samples != [] and Enum.all?(progress(samples), fn {_axis, value} -> value >= 1.0 end))
  end

  defp outside_corners(corners, columns) do
    {Enum.at(corners, 0), Enum.at(corners, columns - 1), List.last(corners),
     Enum.at(corners, -columns)}
  end

  defp area({ulx, uly}, {urx, ury}, {drx, dry}, {dlx, dly}) do
    {px, py} = {dlx - urx, dly - ury}
    {qx, qy} = {drx - ulx, dry - uly}
    abs(px * qy - py * qx) / 2
  end

  defp skew({ulx, uly}, {urx, ury}, {drx, dry}) do
    {abx, aby} = {ulx - urx, uly - ury}
    {cbx, cby} = {drx - urx, dry - ury}
    norms = :math.sqrt(abx * abx + aby * aby) * :math.sqrt(cbx * cbx + cby * cby)

    if norms == 0 do
      0.0
    else
      cosine = max(-1.0, min(1.0, (abx * cbx + aby * cby) / norms))
      min(1.0, 2 * abs(:math.pi() / 2 - :math.acos(cosine)))
    end
  end

  defp distance(first, second) do
    Enum.sum(for axis <- [:x, :y, :size, :skew], do: abs(first[axis] - second[axis]))
  end

  defp clamp(value), do: min(1.0, max(0.0, value))
end
