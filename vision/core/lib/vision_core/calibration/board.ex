defmodule VisionCore.Calibration.Board do
  @moduledoc """
  A chessboard calibration target, described by its inner corners.

  `columns` and `rows` count inner corners (an 8 x 6 board has 9 x 7 squares).
  They must differ so the board orientation is unambiguous. `square_m` is the
  side of one square in meters.
  """

  @enforce_keys [:columns, :rows, :square_m]
  defstruct [:columns, :rows, :square_m]

  @type t :: %__MODULE__{columns: pos_integer(), rows: pos_integer(), square_m: float()}

  @doc "Builds a board, refusing dimensions OpenCV cannot detect."
  @spec new(integer(), integer(), number()) :: {:ok, t()} | {:error, String.t()}
  def new(columns, rows, square_m) do
    cond do
      not (is_integer(columns) and is_integer(rows)) ->
        {:error, "columns and rows must be integers"}

      columns < 2 or rows < 2 ->
        {:error, "the board needs at least 2 inner corners per side"}

      columns == rows ->
        {:error, "columns and rows must differ"}

      not (is_number(square_m) and square_m > 0) ->
        {:error, "the square size must be positive"}

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
