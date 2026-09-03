defmodule RosBridge.Perception.Fusion do
  @moduledoc """
  Turns a 2D detection box plus a metric depth map into a position
  and size in metres. Pure geometry — no processes, no publishing —
  so the arithmetic that decides where a detection *is* can be tested
  against a hand-built depth map rather than only against the road.

  Both inputs live in the rectified left camera's frame, pixel for
  pixel, which is what makes this a lookup rather than a registration
  problem: the stereo backend rectifies the image it detects on and
  computes depth from the same rectified pair.
  """

  @doc """
  Median of the valid depths in the central `fraction` of `box`.

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
  @spec median_depth(Evision.Mat.t(), map(), float()) :: float() | nil
  def median_depth(depth_m, box, fraction) do
    {height, width} = mat_hw(depth_m)

    {x0, x1} = shrink(box.x0, box.x1, fraction, width)
    {y0, y1} = shrink(box.y0, box.y1, fraction, height)

    if x1 > x0 and y1 > y0 do
      depth_m[[y0..(y1 - 1)//1, x0..(x1 - 1)//1]]
      |> Evision.Mat.to_binary()
      |> valid_depths()
      |> median()
    end
  end

  @doc """
  Unproject a box at distance `z` into metres, using the rectified
  intrinsics. Square pixels after rectification, so `fy == fx`.

  Returns the box centre as `{x, y, z}` plus its metric `width` and
  `height`. The frame is optical — x right, y down, z forward — which
  is why a marker's label goes at a *smaller* y to sit above the box.
  """
  @spec unproject(map(), float(), {float(), float()}, float()) :: map()
  def unproject(box, z, {cx, cy}, fx) do
    u = (box.x0 + box.x1) / 2.0
    v = (box.y0 + box.y1) / 2.0

    %{
      x: (u - cx) * z / fx,
      y: (v - cy) * z / fx,
      z: z,
      width: (box.x1 - box.x0) * z / fx,
      height: (box.y1 - box.y0) * z / fx
    }
  end

  @doc """
  The perimeter of `box` as ordered vertices for a `LINE_LOOP` — the
  loop closes itself, so the last vertex is not repeated.

  Each edge is subdivided into `segments` pieces rather than drawn
  corner to corner. A straight edge in rectified pixels is a *curve*
  in raw camera pixels, and the overlay is drawn on the raw image:
  measured on the Mini, rectification moves a pixel by 10 on average
  and up to 23, so an undivided edge visibly bows away from the
  object. Subdividing lets `remap/4` follow the distortion.

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

  # An edge's vertices, excluding its end corner — the next edge
  # starts there, and repeating it would double every corner.
  defp subdivide({x0, y0}, {x1, y1}, segments) do
    Enum.map(0..(segments - 1), fn i ->
      t = i / segments
      {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t}
    end)
  end

  @doc """
  Map a rectified pixel back to its raw camera pixel, using the
  fixed-point rectification map OpenCV produced (`CV_16SC2` —
  interleaved int16 x, y per rectified pixel), passed in as its raw
  binary.

  This is what lets a box computed in rectified coordinates be drawn
  on the raw image the pipeline actually publishes, rather than
  putting a second, rectified image stream on the wire.

  Out-of-range coordinates return `nil`; the caller drops that vertex
  rather than drawing to a garbage position.
  """
  @spec remap(binary(), pos_integer(), pos_integer(), {number(), number()}) ::
          {float(), float()} | nil
  def remap(map_binary, width, height, {x, y}) do
    column = x |> round() |> min(width - 1) |> max(0)
    row = y |> round() |> min(height - 1) |> max(0)
    offset = (row * width + column) * 4

    case map_binary do
      <<_skip::binary-size(offset), raw_x::little-signed-16, raw_y::little-signed-16,
        _rest::binary>> ->
        {raw_x / 1.0, raw_y / 1.0}

      _ ->
        nil
    end
  end

  # Shrink a span towards its centre, then clamp to the image. The
  # clamp matters: a detection cut off at the frame edge legitimately
  # has a box extending past it.
  defp shrink(low, high, fraction, limit) do
    centre = (low + high) / 2.0
    half = (high - low) * fraction / 2.0

    {
      low |> max(centre - half) |> round() |> max(0),
      high |> min(centre + half) |> round() |> min(limit)
    }
  end

  # The upper bound rejects the infinities a zero disparity produces
  # before they reach the median.
  defp valid_depths(binary) do
    for <<value::little-float-32 <- binary>>,
        value > 0.0 and value < 1.0e6,
        do: value
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

  defp mat_hw(mat) do
    case Evision.Mat.shape(mat) do
      {height, width} -> {height, width}
      {height, width, _channels} -> {height, width}
    end
  end
end
