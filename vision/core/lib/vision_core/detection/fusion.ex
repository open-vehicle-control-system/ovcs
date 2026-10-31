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
  The rectification map of `calibration` as `remap/4` reads it: for each
  rectified pixel, row-major, the raw pixel's `x, y` as little-endian
  int16, OpenCV's `CV_16SC2` layout. Computed on the CPU, once per
  calibration.
  """
  @spec rectification_map(CameraCalibration.t()) :: binary()
  def rectification_map(%CameraCalibration{} = calibration) do
    camera =
      NxStereo.Rectify.camera(
        calibration.camera_matrix,
        calibration.distortion_coefficients,
        calibration.rectification_matrix,
        calibration.projection_matrix
      )

    image = Nx.broadcast(Nx.tensor(0, type: :u8), {calibration.height, calibration.width})

    {map_x, map_y} =
      Nx.Defn.jit(&NxStereo.Rectify.maps/2, compiler: Nx.Defn.Evaluator).(image, camera)

    # OpenCV's fixed point: 1/32 pixel, rounded down to the integer part.
    [map_x, map_y]
    |> Enum.map(&(&1 |> Nx.multiply(32) |> Nx.round() |> Nx.divide(32) |> Nx.floor()))
    |> Nx.stack(axis: -1)
    |> Nx.as_type(:s16)
    |> Nx.to_binary()
  end

  @doc """
  Map a rectified pixel back to its raw camera pixel through a
  rectification map (`rectification_map/1`): interleaved int16 x, y per
  rectified pixel, as a binary.

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
      <<_skip::binary-size(^offset), raw_x::little-signed-16, raw_y::little-signed-16,
        _rest::binary>> ->
        {raw_x / 1.0, raw_y / 1.0}

      _ ->
        nil
    end
  end

  @doc """
  The left camera's rectification map for `pair` (`rectification_map/1`),
  `nil` without a calibration, and the cache to pass next time: the map
  is computed once per calibration.
  """
  @spec left_rectification_map(Pair.t(), cache) :: {binary() | nil, cache}
        when cache: {term(), binary()} | nil
  def left_rectification_map(%Pair{geometry: %{left_calibration: nil}}, cache), do: {nil, cache}

  def left_rectification_map(
        %Pair{geometry: %{left_calibration: calibration}},
        {calibration, map_binary} = cache
      ),
      do: {map_binary, cache}

  def left_rectification_map(%Pair{geometry: %{left_calibration: calibration}}, _cache) do
    map_binary = rectification_map(calibration)
    {map_binary, {calibration, map_binary}}
  end

  def left_rectification_map(%Pair{}, cache), do: {nil, cache}

  @doc """
  A rectified pixel of `pair` as a pixel of its left camera frame: mapped
  back through `map_binary` (`left_rectification_map/2`), then scaled from
  the matching size to the frame's, which the pipeline may shrink. `nil`
  when the map sends it outside the image; without a map, only scaled.
  """
  @spec raw_point({number(), number()}, binary() | nil, Pair.t()) :: {float(), float()} | nil
  def raw_point(vertex, nil, pair), do: to_frame_scale(vertex, pair)

  def raw_point(vertex, map_binary, %Pair{} = pair) do
    {width, height} = Pair.size(pair)

    case remap(map_binary, width, height, vertex) do
      nil -> nil
      raw -> to_frame_scale(raw, pair)
    end
  end

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
