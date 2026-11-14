defmodule VisionCore.Calibration.Board do
  @moduledoc """
  A chessboard calibration target, described by its inner corners.

  `columns` and `rows` count inner corners (an 8 x 6 board has 9 x 7 squares),
  from 3, the fewest OpenCV looks for, to `max_corners/0` per side. They must
  differ so the board orientation is unambiguous. `square_m` is the side of
  one square in meters, at most `max_square_m/0`.
  """

  @min_corners 3
  @max_corners 50
  @max_square_m 1.0

  @enforce_keys [:columns, :rows, :square_m]
  defstruct [:columns, :rows, :square_m]

  @type t :: %__MODULE__{columns: pos_integer(), rows: pos_integer(), square_m: float()}

  @doc "The most inner corners a board has per side."
  @spec max_corners() :: pos_integer()
  def max_corners, do: @max_corners

  @doc "The largest side of a square, in meters."
  @spec max_square_m() :: float()
  def max_square_m, do: @max_square_m

  @doc "Builds a board, refusing dimensions OpenCV cannot detect."
  @spec new(integer(), integer(), number()) :: {:ok, t()} | {:error, String.t()}
  def new(columns, rows, square_m) do
    cond do
      not (is_integer(columns) and is_integer(rows)) ->
        {:error, "columns and rows must be integers"}

      columns < @min_corners or rows < @min_corners ->
        {:error, "the board needs at least #{@min_corners} inner corners per side"}

      columns > @max_corners or rows > @max_corners ->
        {:error, "the board has at most #{@max_corners} inner corners per side"}

      columns == rows ->
        {:error, "columns and rows must differ"}

      not (is_number(square_m) and square_m > 0 and square_m <= @max_square_m) ->
        {:error, "the square size must be above 0 and at most #{@max_square_m} m"}

      true ->
        {:ok, %__MODULE__{columns: columns, rows: rows, square_m: square_m}}
    end
  end

  @doc "The inner corners in board coordinates (meters, z = 0), row by row."
  @spec object_points(t()) :: [{float(), float(), float()}]
  def object_points(%__MODULE__{columns: columns, rows: rows, square_m: square_m}) do
    for row <- 0..(rows - 1), column <- 0..(columns - 1) do
      {column * square_m, row * square_m, 0.0}
    end
  end
end
