defmodule VisionCore.Detection.Reprojection do
  @moduledoc """
  The stereo depth seen from a camera of its own (`VisionCore.Camera.Unit`):
  each measured pixel of a pair's depth map, as a point in the rectified
  left optical frame, moved into the camera's optical frame by its
  `VisionCore.Camera.Pose` and projected through its calibration into its
  image. `VisionCore.Detection.Fusion` places a box on that camera from the
  points that land inside it.

  Two lens models, the calibration's `distortion_model`:

    * `"plumb_bob"`, as OpenCV's `projectPoints`: `k1, k2, p1, p2, k3`.
    * `"equidistant"`, as OpenCV's `fisheye::projectPoints`: `k1` to `k4`,
      on the angle off the optical axis, `θ = atan2(r, z)`, which a fisheye
      lens sees past 90°.

  A point is in the camera's view when it lands inside the image without
  passing the lens's fold: the radius where the radial distortion stops
  growing and starts mapping farther points back towards the centre. A
  plumb_bob point must also be in front of the camera (`z > 0`) and
  inside the radius the fold is searched over; a fisheye point needs only
  an angle below the fold.

  The camera matrix's skew, `K[0][1]`, applies too, which OpenCV's
  `projectPoints` and `fisheye::projectPoints` leave out; calibrations
  from OpenCV have none.

  The calibration is the one of the camera's frames: one saved at another
  size is scaled to it with `VisionCore.Ros2.CameraCalibration.scale_to/3`
  first.

  The projection runs in plain Elixir over the depth binary: Nx has no
  compiled CPU backend on the vision boards, its binary backend is many
  times slower on this many points, and it holds no empty tensor, which
  a pair with no point in the camera's view gives. The hot functions
  guard their numbers as floats, which lets the JIT use float
  instructions.
  """

  alias VisionCore.Camera.Pose
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @default_stride 2
  @models %{"plumb_bob" => :plumb_bob, "equidistant" => :equidistant}
  @coefficient_counts %{"plumb_bob" => 5, "equidistant" => 4}

  # Where the fold is searched: r² for plumb_bob, θ in radians for equidistant.
  @plumb_bob_fold_search {0.0, 100.0}
  @equidistant_fold_search {0.0, :math.pi()}
  @fold_search_steps 1_000
  @fold_bisections 60
  @undistort_iterations 50
  # How far an undistorted pixel may land from itself once distorted back.
  @converged_px 0.1

  @typedoc """
  The points that land in the camera's image: `count` of them, each its
  pixel `u`, `v` and its depth `z` along the camera's optical axis in
  metres, as native-endian 32-bit floats, `u, v, z` after one another.
  """
  @type points :: %{count: non_neg_integer(), points: binary()}

  @typedoc """
  `t:points/0` with where each point is in the rectified left optical
  frame: its pixel `u`, `v`, then its `x`, `y`, `z` in metres in that
  frame, as native-endian 32-bit floats, `u, v, x, y, z` after one another.
  """
  @type points_with_origin :: %{count: non_neg_integer(), points: binary()}

  defguardp is_floats(first, second) when is_float(first) and is_float(second)

  defguardp is_floats(first, second, third)
            when is_float(first) and is_float(second) and is_float(third)

  defmodule Lens do
    @moduledoc false
    defstruct [:model, :coefficients, :camera, :fold]
  end

  @typedoc "A calibration read once for projecting with, by `lens/1`."
  @opaque lens :: %Lens{}

  @typedoc "A camera's calibration, or its `t:lens/0`."
  @type camera :: CameraCalibration.t() | lens()

  @typedoc "A unit direction in the camera's optical frame."
  @type ray :: {float(), float(), float()}

  @doc """
  `:ok` when `calibration` can be projected with, `{:error, message}`
  otherwise: a distortion model other than plumb_bob and equidistant,
  more coefficients than the model takes (5 and 4; fewer are zeros), no
  focal length or no image size. The size is the camera frames' one, so
  a calibration saved at another size goes through
  `VisionCore.Ros2.CameraCalibration.scale_to/3` first, and one without
  a size gets the frames' from it.
  """
  @spec check(CameraCalibration.t()) :: :ok | {:error, String.t()}
  def check(%CameraCalibration{} = calibration) do
    with :ok <- check_lens(calibration), do: check_size(calibration)
  end

  @doc """
  `check/1` without the image size: whether `calibration`'s lens can be
  projected with at any size, for a calibration not yet scaled to the
  frames.
  """
  @spec check_lens(CameraCalibration.t()) :: :ok | {:error, String.t()}
  def check_lens(%CameraCalibration{} = calibration) do
    with :ok <- check_model(calibration),
         :ok <- check_coefficients(calibration),
         do: check_focal_length(calibration)
  end

  @doc """
  `calibration` read for projecting with: its camera matrix, its
  distortion and the fold of its distortion, which the other functions
  otherwise work out from the calibration at each call. Raises
  `ArgumentError` for a calibration `check/1` refuses.
  """
  @spec lens(CameraCalibration.t()) :: lens()
  def lens(%CameraCalibration{} = calibration) do
    case check(calibration) do
      :ok -> read_lens(calibration)
      {:error, message} -> raise ArgumentError, "#{inspect(__MODULE__)}: #{message}"
    end
  end

  @doc """
  Every `stride`-th pixel of every `stride`-th row of `pair`'s depth map
  that has a depth, unprojected with the rectified left intrinsics, moved
  by `pose` and projected through `camera`: the `t:points/0` in the
  camera's view (see the moduledoc), row by row. Raises `ArgumentError`
  for a calibration `check/1` refuses.
  """
  @spec project(Pair.t(), camera(), Pose.t(), pos_integer()) :: points()
  def project(pair, camera, pose, stride \\ @default_stride),
    do: project(pair, camera, pose, stride, :camera)

  @doc """
  `project/4`'s points, each with where it is in the rectified left
  optical frame, the stereo pair's: its pixel `u`, `v` in the camera's
  image, then its `x`, `y`, `z` in metres in the left optical frame, as
  native-endian 32-bit floats, `u, v, x, y, z` after one another.
  """
  @spec project_with_origin(Pair.t(), camera(), Pose.t(), pos_integer()) :: points_with_origin()
  def project_with_origin(pair, camera, pose, stride \\ @default_stride),
    do: project(pair, camera, pose, stride, :origin)

  defp project(%Pair{} = pair, camera, %Pose{} = pose, stride, record)
       when is_integer(stride) and stride > 0 do
    lens = to_lens(camera)
    {width, height} = Pair.size(pair)
    {cx, cy} = pair.geometry.principal_point
    fx = pair.geometry.focal_length_px / 1

    columns = %{
      first_x: -cx / fx,
      x_step: stride / fx,
      skip_bytes: (stride - 1) * 2,
      record: record
    }

    points =
      Enum.reduce(0..(height - 1)//stride, <<>>, fn row, points ->
        depths = binary_part(pair.depth, row * width * 2, width * 2)
        ray = row_ray(pose, (row - cy) / fx)
        project_row(depths, columns.first_x, columns, ray, lens, points)
      end)

    %{count: div(byte_size(points), record_bytes(record)), points: points}
  end

  defp record_bytes(:camera), do: 12
  defp record_bytes(:origin), do: 20

  @doc """
  The unit direction, in the camera's optical frame, of what `pixel` of
  `camera` sees: the pixel undistorted as OpenCV's `undistortPoints`
  (plumb_bob) or `fisheye::undistortPoints` (equidistant) does, iterated
  to convergence. A fisheye direction may point past 90° off-axis
  (`z <= 0`). Raises `ArgumentError` for a calibration `check/1` refuses.

  `nil` for a pixel past the lens's fold, which no direction in view
  lands on: a fisheye pixel farther from the centre than the fold's,
  and a plumb_bob one whose undistortion does not converge inside the
  fold, its direction distorted back landing more than 0.1 px away.
  """
  @spec ray(camera(), {number(), number()}) :: ray() | nil
  def ray(camera, pixel), do: camera |> rays([pixel]) |> hd()

  @doc "`ray/2` for each of `pixels`, `nil` for each past the fold, reading `camera` once."
  @spec rays(camera(), [{number(), number()}]) :: [ray() | nil]
  def rays(camera, pixels) do
    lens = to_lens(camera)
    {fx, skew, cx, fy, cy, _width, _height} = lens.camera

    Enum.map(pixels, fn {u, v} ->
      distorted_y = (v - cy) / fy
      distorted_x = (u - cx - skew * distorted_y) / fx
      undistort(lens, distorted_x, distorted_y)
    end)
  end

  @doc """
  `{azimuth, elevation}` in radians of what `pixel` sees (`ray/2`), in the
  camera's optical frame: azimuth positive to the right, elevation
  positive up. `nil` for a pixel past the lens's fold.
  """
  @spec bearing(camera(), {number(), number()}) :: {float(), float()} | nil
  def bearing(camera, pixel) do
    case ray(camera, pixel) do
      {x, y, z} -> {:math.atan2(x, z), :math.atan2(-y, :math.sqrt(x * x + z * z))}
      nil -> nil
    end
  end

  defp check_model(%{distortion_model: model}) when is_map_key(@models, model), do: :ok

  defp check_model(%{distortion_model: model}),
    do: {:error, "distortion model #{inspect(model)} is neither plumb_bob nor equidistant"}

  defp check_coefficients(%{distortion_model: model, distortion_coefficients: coefficients}) do
    count = Map.fetch!(@coefficient_counts, model)

    if length(coefficients) <= count,
      do: :ok,
      else:
        {:error, "#{model} takes #{count} distortion coefficients, not #{length(coefficients)}"}
  end

  defp check_focal_length(%{camera_matrix: [fx, _, _, _, fy | _]}) when fx > 0 and fy > 0,
    do: :ok

  defp check_focal_length(_calibration), do: {:error, "the camera matrix has no focal length"}

  defp check_size(%{width: width, height: height}) when width > 0 and height > 0, do: :ok
  defp check_size(_calibration), do: {:error, "the calibration has no image size"}

  defp to_lens(%Lens{} = lens), do: lens
  defp to_lens(%CameraCalibration{} = calibration), do: lens(calibration)

  # Every number a float, which the hot functions' guards require.
  defp read_lens(%CameraCalibration{distortion_model: model} = calibration) do
    [fx, skew, cx, _, fy, cy | _] = Enum.map(calibration.camera_matrix, &(&1 / 1))
    count = Map.fetch!(@coefficient_counts, model)

    coefficients =
      calibration.distortion_coefficients
      |> Enum.map(&(&1 / 1))
      |> Kernel.++(List.duplicate(0.0, count - length(calibration.distortion_coefficients)))
      |> List.to_tuple()

    lens = %Lens{
      model: Map.fetch!(@models, model),
      coefficients: coefficients,
      camera: {fx, skew, cx, fy, cy, calibration.width / 1, calibration.height / 1}
    }

    %{lens | fold: fold(lens)}
  end

  # R · (x, y, 1) for a row's y: R's first column, times x, plus the row's part, then t; and y.
  defp row_ray(%Pose{rotation: rotation, translation: translation}, row_y) do
    [r00, r01, r02, r10, r11, r12, r20, r21, r22] = Enum.map(rotation, &(&1 / 1))
    [tx, ty, tz] = Enum.map(translation, &(&1 / 1))

    {{r00, r10, r20}, {r01 * row_y + r02, r11 * row_y + r12, r21 * row_y + r22}, {tx, ty, tz},
     row_y / 1}
  end

  defp project_row(<<millimetres::little-16, rest::binary>>, left_x, columns, ray, lens, points)
       when is_float(left_x) do
    points =
      if millimetres > 0,
        do: project_point(millimetres / 1000, left_x, ray, lens, {columns.record, points}),
        else: points

    project_row(
      skip(rest, columns.skip_bytes),
      left_x + columns.x_step,
      columns,
      ray,
      lens,
      points
    )
  end

  defp project_row(<<>>, _left_x, _columns, _ray, _lens, points), do: points

  defp skip(depths, bytes) do
    case depths do
      <<_skipped::binary-size(^bytes), rest::binary>> -> rest
      _row_end -> <<>>
    end
  end

  defp project_point(
         depth_m,
         left_x,
         {{r00, r10, r20}, {row_x, row_y, row_z}, {tx, ty, tz}, left_y},
         lens,
         {record, points}
       )
       when is_floats(r00, r10, r20) and is_floats(row_x, row_y, row_z) and
              is_floats(tx, ty, tz) and is_floats(depth_m, left_x, left_y) do
    x = depth_m * (r00 * left_x + row_x) + tx
    y = depth_m * (r10 * left_x + row_y) + ty
    z = depth_m * (r20 * left_x + row_z) + tz

    with {distorted_x, distorted_y} <- distort(lens, x, y, z),
         {u, v} <- pixel(lens.camera, distorted_x, distorted_y) do
      case record do
        :camera ->
          <<points::binary, u::float-32-native, v::float-32-native, z::float-32-native>>

        :origin ->
          <<points::binary, u::float-32-native, v::float-32-native,
            depth_m * left_x::float-32-native, depth_m * left_y::float-32-native,
            depth_m::float-32-native>>
      end
    else
      :outside -> points
    end
  end

  defp distort(%{model: :plumb_bob, fold: fold, coefficients: coefficients}, x, y, z)
       when is_floats(x, y, z) and z > 0.0 do
    normal_x = x / z
    normal_y = y / z
    radius_squared = normal_x * normal_x + normal_y * normal_y

    if radius_squared < fold,
      do: plumb_bob(coefficients, normal_x, normal_y, radius_squared),
      else: :outside
  end

  defp distort(%{model: :plumb_bob}, _x, _y, _z), do: :outside

  defp distort(%{model: :equidistant, fold: fold, coefficients: coefficients}, x, y, z)
       when is_floats(x, y, z) do
    radius = :math.sqrt(x * x + y * y)
    angle = :math.atan2(radius, z)

    cond do
      angle >= fold -> :outside
      radius == 0.0 -> {0.0, 0.0}
      true -> equidistant_direction(coefficients, angle, radius, x, y)
    end
  end

  defp plumb_bob({k1, k2, p1, p2, k3}, x, y, radius_squared)
       when is_floats(k1, k2, k3) and is_floats(p1, p2, radius_squared) and is_floats(x, y) do
    radial = 1.0 + radius_squared * (k1 + radius_squared * (k2 + radius_squared * k3))

    {x * radial + 2.0 * p1 * x * y + p2 * (radius_squared + 2.0 * x * x),
     y * radial + p1 * (radius_squared + 2.0 * y * y) + 2.0 * p2 * x * y}
  end

  defp equidistant_direction(coefficients, angle, radius, x, y)
       when is_floats(radius, x, y) do
    scale = equidistant(coefficients, angle) / radius
    {x * scale, y * scale}
  end

  defp equidistant({k1, k2, k3, k4}, angle)
       when is_floats(k1, k2, k3) and is_floats(k4, angle) do
    squared = angle * angle
    angle * (1.0 + squared * (k1 + squared * (k2 + squared * (k3 + squared * k4))))
  end

  defp pixel({fx, skew, cx, fy, cy, width, height}, distorted_x, distorted_y)
       when is_floats(fx, skew, cx) and is_floats(fy, cy, width) and
              is_floats(height, distorted_x, distorted_y) do
    u = fx * distorted_x + skew * distorted_y + cx
    v = fy * distorted_y + cy

    if u >= 0.0 and u < width and v >= 0.0 and v < height,
      do: {u, v},
      else: :outside
  end

  # The radial distortion's derivative, whose first zero is the fold.
  defp fold(%{model: :plumb_bob, coefficients: {k1, k2, _p1, _p2, k3}}) do
    first_zero(@plumb_bob_fold_search, fn radius_squared ->
      1 + radius_squared * (3 * k1 + radius_squared * (5 * k2 + radius_squared * 7 * k3))
    end)
  end

  defp fold(%{model: :equidistant, coefficients: {k1, k2, k3, k4}}) do
    first_zero(@equidistant_fold_search, fn angle ->
      squared = angle * angle
      1 + squared * (3 * k1 + squared * (5 * k2 + squared * (7 * k3 + squared * 9 * k4)))
    end)
  end

  # The first value in `{low, high}` where `derivative` reaches zero, `high` when it does not.
  defp first_zero({low, high}, derivative) do
    step = (high - low) / @fold_search_steps

    1..@fold_search_steps
    |> Enum.find(&(derivative.(low + &1 * step) <= 0))
    |> case do
      nil -> high
      index -> bisect(low + (index - 1) * step, low + index * step, derivative)
    end
  end

  defp bisect(positive, non_positive, derivative) do
    Enum.reduce(1..@fold_bisections, {positive, non_positive}, fn _bisection, {low, high} ->
      middle = (low + high) / 2
      if derivative.(middle) > 0, do: {middle, high}, else: {low, middle}
    end)
    |> elem(0)
  end

  defp undistort(%{model: :plumb_bob} = lens, distorted_x, distorted_y) do
    with {x, y} <- plumb_bob_inverse(lens, distorted_x, distorted_y),
         true <- x * x + y * y < lens.fold,
         true <- converged?(lens, {x, y}, {distorted_x, distorted_y}) do
      normalise({x, y, 1.0})
    else
      _diverged_or_folded -> nil
    end
  end

  defp undistort(%{model: :equidistant} = lens, distorted_x, distorted_y) do
    distorted_angle = :math.sqrt(distorted_x * distorted_x + distorted_y * distorted_y)

    cond do
      distorted_angle == 0.0 ->
        {0.0, 0.0, 1.0}

      distorted_angle > equidistant(lens.coefficients, lens.fold) ->
        nil

      true ->
        angle = equidistant_angle(lens, distorted_angle)
        scale = :math.sin(angle) / distorted_angle
        {distorted_x * scale, distorted_y * scale, :math.cos(angle)}
    end
  end

  # OpenCV's fixed-point iteration, given up once it runs off past the fold's search.
  defp plumb_bob_inverse(%{coefficients: {k1, k2, p1, p2, k3}}, distorted_x, distorted_y) do
    {_low, search_limit} = @plumb_bob_fold_search

    Enum.reduce_while(1..@undistort_iterations, {distorted_x, distorted_y}, fn _iteration,
                                                                               {x, y} ->
      radius_squared = x * x + y * y
      radial = 1 + radius_squared * (k1 + radius_squared * (k2 + radius_squared * k3))
      tangential_x = 2 * p1 * x * y + p2 * (radius_squared + 2 * x * x)
      tangential_y = p1 * (radius_squared + 2 * y * y) + 2 * p2 * x * y

      if radius_squared < search_limit and radial > 0,
        do:
          {:cont, {(distorted_x - tangential_x) / radial, (distorted_y - tangential_y) / radial}},
        else: {:halt, :diverged}
    end)
  end

  defp converged?(
         %{coefficients: coefficients, camera: camera},
         {x, y},
         {distorted_x, distorted_y}
       ) do
    {fx, skew, _cx, fy, _cy, _width, _height} = camera
    {again_x, again_y} = plumb_bob(coefficients, x, y, x * x + y * y)
    error_u = fx * (again_x - distorted_x) + skew * (again_y - distorted_y)
    error_v = fy * (again_y - distorted_y)
    error_u * error_u + error_v * error_v <= @converged_px * @converged_px
  end

  # Newton's method on θ_d(θ) = distorted_angle, kept below the fold.
  defp equidistant_angle(
         %{coefficients: {k1, k2, k3, k4} = coefficients, fold: fold},
         distorted_angle
       ) do
    Enum.reduce(1..@undistort_iterations, distorted_angle, fn _iteration, angle ->
      squared = angle * angle

      slope =
        1 + squared * (3 * k1 + squared * (5 * k2 + squared * (7 * k3 + squared * 9 * k4)))

      next = angle - (equidistant(coefficients, angle) - distorted_angle) / slope
      next |> max(0.0) |> min(fold)
    end)
  end

  defp normalise({x, y, z}) do
    length = :math.sqrt(x * x + y * y + z * z)
    {x / length, y / length, z / length}
  end
end
