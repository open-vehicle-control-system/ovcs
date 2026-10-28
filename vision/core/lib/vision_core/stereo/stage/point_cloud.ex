defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects the metric depth into `x, y, z` points in the left optical
  frame, keeping one point every `:decimation` pixels (`4`) in each
  direction: the full grid is 12 bytes a pixel, more than one Zenoh
  session drains next to the disparity and depth images. Points outside
  5 cm to 20 m carry no measurement and are dropped.
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Stereo.Pair

  @min_point_depth_m 0.05
  @max_point_depth_m 20.0

  @impl VisionCore.Stereo.Stage
  def init(opts, context) do
    {:ok,
     %{
       decimation: Keyword.get(opts, :decimation, 4),
       focal_length_px: context.focal_length_px,
       principal_point: context.principal_point
     }}
  end

  @impl VisionCore.Stereo.Stage
  def requires, do: [:depth_m]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:cloud, :cloud_points]

  # Explicit unprojection of the validated depth rather than `reprojectImageTo3D/2` + Q.
  @impl VisionCore.Stereo.Stage
  def run(%Pair{depth_m: depth_m} = pair, state) do
    {cx, cy} = state.principal_point
    step = state.decimation
    {height, width} = Evision.Mat.shape(depth_m)
    {cloud_width, cloud_height} = {div(width, step), div(height, step)}

    z =
      Evision.resize(depth_m, {cloud_width, cloud_height},
        interpolation: Evision.Constant.cv_INTER_NEAREST()
      )

    scale = 1.0 / step
    z_over_fx = Evision.divide(z, state.focal_length_px * scale)

    x =
      Evision.multiply(
        Evision.subtract(column_grid(cloud_width, cloud_height), cx * scale),
        z_over_fx
      )

    y =
      Evision.multiply(
        Evision.subtract(row_grid(cloud_width, cloud_height), cy * scale),
        z_over_fx
      )

    {cloud, count} =
      [x, y, z]
      |> Evision.merge()
      |> Evision.Mat.to_binary()
      |> points_in_range()

    {:ok, %{pair | cloud: cloud, cloud_points: count}, state}
  end

  defp column_grid(width, height) do
    row = for u <- 0..(width - 1), into: <<>>, do: <<u * 1.0::little-float-32>>
    Evision.Mat.from_binary(:binary.copy(row, height), {:f, 32}, height, width, 1)
  end

  defp row_grid(width, height) do
    binary =
      for v <- 0..(height - 1), into: <<>>, do: :binary.copy(<<v * 1.0::little-float-32>>, width)

    Evision.Mat.from_binary(binary, {:f, 32}, height, width, 1)
  end

  # Unmatched pixels (depth 0) are dropped, not packed as a phantom point at the origin.
  defp points_in_range(binary) do
    {chunks, count} =
      for <<x::little-float-32, y::little-float-32, z::little-float-32 <- binary>>,
          z > @min_point_depth_m and z < @max_point_depth_m,
          reduce: {[], 0} do
        {chunks, count} ->
          {[<<x::little-float-32, y::little-float-32, z::little-float-32>> | chunks], count + 1}
      end

    {chunks |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end
end
