defmodule VisionCore.Detection.Fusion do
  @moduledoc """
  Turns a 2D detection box plus a depth image into a position
  and size in metres. Pure geometry — no processes, no publishing —
  so the arithmetic that decides where a detection *is* can be tested
  against a hand-built depth image rather than only against the road.

  Both inputs live in the rectified left camera's frame, pixel for
  pixel, which is what makes this a lookup rather than a registration
  problem: the stereo pipeline rectifies the image it detects on and
  computes depth from the same rectified pair.
  """

  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @doc """
  Median of the valid depths in the central `fraction` of `box`, in
  metres, from `depth_mm`: the pair's depth image, `{width, height}`
  16-bit millimetres, row-major.

  Median rather than mean because a box drawn around a person still
  contains background at its corners, and a mean is dragged towards
  the wall behind them. Sampling only the middle of the box cuts most
  of that background out before the median has to reject it.

  Zero is the ROS "no measurement" value in a depth image, so zeros
  are excluded rather than averaged in as 0 m. Returns `nil` when
  nothing valid falls inside — stereo genuinely returns nothing on
  untextured surfaces, and the caller is expected to drop the
  detection rather than invent a range for it.
  """
  @spec median_depth(binary(), {pos_integer(), pos_integer()}, map(), float()) :: float() | nil
  def median_depth(depth_mm, {width, height}, box, fraction) do
    {x0, x1} = shrink(box.x0, box.x1, fraction, width)
    {y0, y1} = shrink(box.y0, box.y1, fraction, height)

    if x1 > x0 and y1 > y0 do
      y0..(y1 - 1)//1
      |> Enum.flat_map(&row_depths(depth_mm, (&1 * width + x0) * 2, (x1 - x0) * 2))
      |> median()
    end
  end

  @doc """
  Unproject a box at `distance_m` into metres, using the rectified
  intrinsics. Square pixels after rectification, so `fy == fx`.

  Returns the box centre as `{x, y, z}` plus its metric `width` and
  `height`. The frame is optical — x right, y down, z forward — which
  is why a marker's label goes at a *smaller* y to sit above the box.
  """
  @spec unproject(map(), float(), {float(), float()}, float()) :: map()
  def unproject(box, distance_m, {cx, cy}, fx) do
    u = (box.x0 + box.x1) / 2.0
    v = (box.y0 + box.y1) / 2.0

    %{
      x: (u - cx) * distance_m / fx,
      y: (v - cy) * distance_m / fx,
      z: distance_m,
      width: (box.x1 - box.x0) * distance_m / fx,
      height: (box.y1 - box.y0) * distance_m / fx
    }
  end

  @doc """
  The perimeter of `box` as ordered vertices for a `LINE_LOOP` — the
  loop closes itself, so the last vertex is not repeated.

  Each edge is subdivided into `segments` pieces rather than drawn
  corner to corner. A straight edge in rectified pixels is a *curve*
  in raw camera pixels, and the overlay is drawn on the raw image, so
  an undivided edge visibly bows away from the object. Subdividing
  lets `remap/4` follow the distortion.

  Returns `4 * segments` vertices.
  """
  @spec perimeter(map(), pos_integer()) :: [{float(), float()}]
  def perimeter(box, segments) when segments >= 1 do
    corners = [
      {box.x0, box.y0},
      {box.x1, box.y0},
      {box.x1, box.y1},
      {box.x0, box.y1}
    ]

    corners
    |> Enum.zip(tl(corners) ++ [hd(corners)])
    |> Enum.flat_map(fn {from, to} -> subdivide(from, to, segments) end)
  end

  # Excludes the end corner, which starts the next edge.
  defp subdivide({x0, y0}, {x1, y1}, segments) do
    Enum.map(0..(segments - 1), fn i ->
      t = i / segments
      {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t}
    end)
  end

  @doc """
  Where rectification samples rectified pixel `{u, v}` of `calibration`'s
  camera: the raw pixel, through the inverse rectifying projection, the
  lens's plumb_bob distortion and the camera matrix, as OpenCV's
  `initUndistortRectifyMap` computes it for every pixel.
  """
  @spec raw_pixel(CameraCalibration.t(), {number(), number()}) :: {float(), float()}
  def raw_pixel(%CameraCalibration{} = calibration, {u, v}) do
    camera =
      NxStereo.Rectify.camera(
        calibration.camera_matrix,
        calibration.distortion_coefficients,
        calibration.rectification_matrix,
        calibration.projection_matrix
      )

    [i0, i1, i2, i3, i4, i5, i6, i7, i8] = Nx.to_flat_list(camera.inverse_pr)
    [k1, k2, p1, p2, k3] = Nx.to_flat_list(camera.d)
    [fx, skew, cx, _, fy, cy | _] = Nx.to_flat_list(camera.k)

    w = i6 * u + i7 * v + i8
    x = (i0 * u + i1 * v + i2) / w
    y = (i3 * u + i4 * v + i5) / w

    r2 = x * x + y * y
    radial = 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
    xd = x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
    yd = y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y

    {fx * xd + skew * yd + cx, fy * yd + cy}
  end

  @doc """
  A rectified pixel of `pair` as a pixel of its left camera frame: mapped
  back through the left calibration (`raw_pixel/2`), then scaled from
  the matching size to the frame's, which the pipeline may shrink.
  Without a calibration, only scaled.
  """
  @spec raw_point({number(), number()}, Pair.t()) :: {float(), float()}
  def raw_point(
        vertex,
        %Pair{geometry: %{left_calibration: %CameraCalibration{} = calibration}} = pair
      ),
      do: calibration |> raw_pixel(vertex) |> to_frame_scale(pair)

  def raw_point(vertex, %Pair{} = pair), do: to_frame_scale(vertex, pair)

  defp to_frame_scale({x, y}, %Pair{left_frame: frame} = pair) do
    {width, height} = Pair.size(pair)
    {x * frame.width / width, y * frame.height / height}
  end

  # Clamped to the image: a box cut off at the frame edge extends past it.
  defp shrink(low, high, fraction, limit) do
    centre = (low + high) / 2.0
    half = (high - low) * fraction / 2.0

    {
      low |> max(centre - half) |> round() |> max(0),
      high |> min(centre + half) |> round() |> min(limit)
    }
  end

  defp row_depths(depth_mm, offset, size) do
    for <<millimetres::little-16 <- binary_part(depth_mm, offset, size)>>,
        millimetres > 0,
        do: millimetres / 1000.0
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2.0
    end
  end
end
