defmodule VisionCore.Calibration.Chessboard do
  @moduledoc """
  Finds the inner corners of a `VisionCore.Calibration.Board` in a frame,
  grey or colour.

  The search runs on a copy downscaled to about 640 x 480 pixels, then the
  corners are refined to sub-pixel accuracy on the full frame.
  """

  alias VisionCore.Calibration.Board
  alias VisionCore.Camera.Frame

  @target_pixels 640 * 480
  @border_px 8
  @refine_iterations 30
  @refine_epsilon 0.1

  @doc """
  The board's corners in `frame`, as `{x, y}` full-frame pixels, row by row
  (`columns` x `rows` of them), the first one in the upper part of the frame.

  `:not_found` when the board is not seen, or when a corner lies within
  #{@border_px} px of the frame's border; `{:error, reason}` for a frame that
  does not decode, or a board OpenCV refuses to look for.
  """
  @spec detect(Frame.t(), Board.t()) ::
          {:ok, [{float(), float()}]} | :not_found | {:error, term()}
  def detect(%Frame{} = frame, %Board{} = board) do
    with {:ok, tensor} <- Frame.to_tensor(frame) do
      {image, width, height} = grey_image(tensor)
      {small, scale_x, scale_y} = downscale(image, width, height)

      with {:ok, found} <- find(small, board),
           corners = Enum.map(found, &to_full_frame(&1, scale_x, scale_y)),
           true <- clear_of_border?(corners, width, height) do
        {:ok, corners |> refine(image, board) |> upright()}
      else
        :not_found -> :not_found
        false -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp grey_image(tensor) do
    case Nx.shape(tensor) do
      {height, width} ->
        {Evision.Mat.from_nx_2d(tensor), width, height}

      {height, width, 3} ->
        colour = Evision.Mat.from_nx_2d(tensor)
        {Evision.cvtColor(colour, Evision.Constant.cv_COLOR_RGB2GRAY()), width, height}
    end
  end

  defp downscale(image, width, height) do
    scale = :math.sqrt(width * height / @target_pixels)

    if scale > 1 do
      small_width = round(width / scale)
      small_height = round(height / scale)

      small =
        Evision.resize(image, {small_width, small_height},
          interpolation: Evision.Constant.cv_INTER_AREA()
        )

      {small, width / small_width, height / small_height}
    else
      {image, 1.0, 1.0}
    end
  end

  defp find(image, %Board{columns: columns, rows: rows}) do
    flags =
      Evision.Constant.cv_CALIB_CB_ADAPTIVE_THRESH() +
        Evision.Constant.cv_CALIB_CB_NORMALIZE_IMAGE() +
        Evision.Constant.cv_CALIB_CB_FAST_CHECK()

    case Evision.findChessboardCorners(image, {columns, rows}, flags: flags) do
      %Evision.Mat{} = corners ->
        {:ok, corners |> Evision.Mat.to_nx() |> Nx.reshape({:auto, 2}) |> Nx.to_list()}

      {:error, reason} ->
        {:error, reason}

      _not_found ->
        :not_found
    end
  end

  defp to_full_frame([x, y], scale_x, scale_y),
    do: {(x + 0.5) * scale_x - 0.5, (y + 0.5) * scale_y - 0.5}

  @doc """
  Whether every corner is at least #{@border_px} px from the border of a
  `width` x `height` frame; refining a corner closer than that would read
  outside the image.
  """
  @spec clear_of_border?([{float(), float()}], pos_integer(), pos_integer()) :: boolean()
  def clear_of_border?(corners, width, height) do
    Enum.all?(corners, fn {x, y} ->
      x >= @border_px and y >= @border_px and x <= width - @border_px and
        y <= height - @border_px
    end)
  end

  defp refine(corners, image, %Board{columns: columns}) do
    half_window = corners |> min_spacing(columns) |> Kernel./(2) |> ceil() |> max(1)

    criteria =
      {Evision.Constant.cv_EPS() + Evision.Constant.cv_MAX_ITER(), @refine_iterations,
       @refine_epsilon}

    corners
    |> Enum.map(fn {x, y} -> [x, y] end)
    |> Nx.tensor(type: :f32)
    |> Nx.reshape({:auto, 1, 2})
    |> Evision.Mat.from_nx()
    |> then(&Evision.cornerSubPix(image, &1, {half_window, half_window}, {-1, -1}, criteria))
    |> Evision.Mat.to_nx()
    |> Nx.reshape({:auto, 2})
    |> Nx.to_list()
    |> Enum.map(fn [x, y] -> {x, y} end)
  end

  defp min_spacing(corners, columns) do
    along_rows = corners |> Enum.chunk_every(columns) |> Enum.flat_map(&neighbour_distances/1)

    along_columns =
      corners
      |> Enum.chunk_every(columns)
      |> Enum.zip_with(& &1)
      |> Enum.flat_map(&neighbour_distances/1)

    Enum.min(along_rows ++ along_columns)
  end

  defp neighbour_distances(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{x1, y1}, {x2, y2}] -> :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2) end)
  end

  defp upright(corners) do
    {_, first_y} = hd(corners)
    {_, last_y} = List.last(corners)
    if first_y > last_y, do: Enum.reverse(corners), else: corners
  end
end
