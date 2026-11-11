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

  A box on a camera of its own is placed from the stereo depth projected
  into that camera's image (`VisionCore.Detection.Reprojection`):
  `projected_depths/3` and `unproject_camera/3`.
  """

  alias VisionCore.Detection.Reprojection
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
  The distance of each of `boxes` on a camera of its own, in metres: the
  median `z` of the stereo `points` projected into its image
  (`Reprojection.project/4`) that fall inside the box's central
  `fraction`, the sample `median_depth/4` takes on the stereo source.
  All boxes in one pass over the points.

  `nil` for a box with no point inside, and for one whose median is not
  in front of the camera: a fisheye box past 90° off-axis, which no
  distance along the optical axis places.
  """
  @spec projected_depths(Reprojection.points(), [map()], float()) :: [float() | nil]
  def projected_depths(_points, [], _fraction), do: []

  def projected_depths(%{points: points}, boxes, fraction) do
    windows = Enum.map(boxes, &central_window(&1, fraction))
    empty = List.to_tuple(List.duplicate([], length(boxes)))

    points
    |> collect_depths(windows, empty)
    |> Tuple.to_list()
    |> Enum.map(&distance_ahead/1)
  end

  @doc """
  `unproject/4` for a box on a camera of its own, through its lens
  model (`Reprojection.rays/2`): the ray through the box's centre at
  `distance_m` along the optical axis, and the width and height between
  the rays through the middles of its opposite edges. `camera` is the
  camera's calibration at the size of its frames, or its
  `Reprojection.lens/1`.

  `nil` when one of those rays is 90° or more off-axis, where a distance
  along the axis places nothing, or has none, its pixel past the lens's
  fold.
  """
  @spec unproject_camera(map(), float(), Reprojection.camera()) :: map() | nil
  def unproject_camera(box, distance_m, camera) do
    middle_u = (box.x0 + box.x1) / 2
    middle_v = (box.y0 + box.y1) / 2

    [centre, left, right, top, bottom] =
      camera
      |> Reprojection.rays([
        {middle_u, middle_v},
        {box.x0, middle_v},
        {box.x1, middle_v},
        {middle_u, box.y0},
        {middle_u, box.y1}
      ])
      |> Enum.map(&axis_plane_point/1)

    if Enum.all?([centre, left, right, top, bottom]) do
      {centre_x, centre_y} = centre

      %{
        x: centre_x * distance_m,
        y: centre_y * distance_m,
        z: distance_m,
        width: (elem(right, 0) - elem(left, 0)) * distance_m,
        height: (elem(bottom, 1) - elem(top, 1)) * distance_m
      }
    end
  end

  # Where a ray crosses the plane 1 m ahead, nil when it never does or there is no ray.
  defp axis_plane_point({x, y, z}) when z > 0, do: {x / z, y / z}
  defp axis_plane_point(_ray), do: nil

  defp central_window(box, fraction) do
    half_width = (box.x1 - box.x0) * fraction / 2
    half_height = (box.y1 - box.y0) * fraction / 2
    middle_u = (box.x0 + box.x1) / 2
    middle_v = (box.y0 + box.y1) / 2
    {middle_u - half_width, middle_u + half_width, middle_v - half_height, middle_v + half_height}
  end

  defp collect_depths(
         <<u::float-32-native, v::float-32-native, z::float-32-native, rest::binary>>,
         windows,
         depths
       ),
       do: collect_depths(rest, windows, add_to_windows(windows, u, v, z, 0, depths))

  defp collect_depths(<<>>, _windows, depths), do: depths

  defp add_to_windows([{left, right, top, bottom} | windows], u, v, z, index, depths)
       when u >= left and u < right and v >= top and v < bottom do
    depths = put_elem(depths, index, [z | elem(depths, index)])
    add_to_windows(windows, u, v, z, index + 1, depths)
  end

  defp add_to_windows([_outside | windows], u, v, z, index, depths),
    do: add_to_windows(windows, u, v, z, index + 1, depths)

  defp add_to_windows([], _u, _v, _z, _index, depths), do: depths

  defp distance_ahead(depths) do
    case median(depths) do
      distance when is_float(distance) and distance > 0 -> distance
      _none_or_behind -> nil
    end
  end

  @doc """
  The perimeter of `box` as ordered vertices for a `LINE_LOOP` — the
  loop closes itself, so the last vertex is not repeated.

  Each edge is subdivided into `segments` pieces rather than drawn
  corner to corner. A straight edge in rectified pixels is a *curve*
  in raw camera pixels, and the overlay is drawn on the raw image, so
  an undivided edge visibly bows away from the object. Subdividing
  lets `raw_points/2` follow the distortion.

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
    Enum.map(0..(segments - 1), fn step ->
      fraction = step / segments
      {x0 + (x1 - x0) * fraction, y0 + (y1 - y0) * fraction}
    end)
  end

  @doc """
  Where rectification samples rectified pixel `{u, v}` of `calibration`'s
  camera: the raw pixel, through the inverse rectifying projection, the
  lens's plumb_bob distortion and the camera matrix, as OpenCV's
  `initUndistortRectifyMap` computes it for every pixel.
  """
  @spec raw_pixel(CameraCalibration.t(), {number(), number()}) :: {float(), float()}
  def raw_pixel(%CameraCalibration{} = calibration, vertex),
    do: calibration |> lens() |> lens_pixel(vertex)

  @doc """
  Rectified pixels of `pair` as pixels of its left camera frame: mapped
  back through the left calibration (`raw_pixel/2`), then scaled from
  the matching size to the frame's, which the pipeline may shrink.
  Without a calibration, only scaled.
  """
  @spec raw_points([{number(), number()}], Pair.t()) :: [{float(), float()}]
  def raw_points(
        vertices,
        %Pair{geometry: %{left_calibration: %CameraCalibration{} = calibration}} = pair
      ) do
    lens = lens(calibration)
    Enum.map(vertices, &(lens |> lens_pixel(&1) |> to_frame_scale(pair)))
  end

  def raw_points(vertices, %Pair{} = pair), do: Enum.map(vertices, &to_frame_scale(&1, pair))

  @doc """
  The outline of each of `boxes` on `pair`'s left camera frame: its
  perimeter (`perimeter/2`, `segments` pieces per edge) as pixels of the
  frame (`raw_points/2`), every box mapped in one pass.
  """
  @spec outlines([map()], pos_integer(), Pair.t()) :: [[{float(), float()}]]
  def outlines([], _segments, _pair), do: []

  def outlines(boxes, segments, %Pair{} = pair) do
    boxes
    |> Enum.flat_map(&perimeter(&1, segments))
    |> raw_points(pair)
    |> Enum.chunk_every(4 * segments)
  end

  # The calibration's inverse rectifying projection, distortion and camera matrix, as numbers.
  defp lens(calibration) do
    camera =
      NxStereo.Rectify.camera(
        calibration.camera_matrix,
        calibration.distortion_coefficients,
        calibration.rectification_matrix,
        calibration.projection_matrix
      )

    %{
      inverse_projection: Nx.to_flat_list(camera.inverse_pr),
      distortion: Nx.to_flat_list(camera.d),
      camera_matrix: Nx.to_flat_list(camera.k)
    }
  end

  defp lens_pixel(lens, {u, v}) do
    [i0, i1, i2, i3, i4, i5, i6, i7, i8] = lens.inverse_projection
    [k1, k2, p1, p2, k3] = lens.distortion
    [fx, skew, cx, _, fy, cy | _] = lens.camera_matrix

    w = i6 * u + i7 * v + i8
    x = (i0 * u + i1 * v + i2) / w
    y = (i3 * u + i4 * v + i5) / w

    r2 = x * x + y * y
    radial = 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
    distorted_x = x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
    distorted_y = y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y

    {fx * distorted_x + skew * distorted_y + cx, fy * distorted_y + cy}
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
