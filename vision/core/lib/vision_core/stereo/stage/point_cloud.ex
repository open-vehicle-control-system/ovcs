defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects the depth pixel of every `:decimation`-th row and column,
  from the first, into an organized grid of `x, y, z` points in the left
  optical frame, on the device: each point from the pixel it samples.
  Points outside 5 cm to 20 m, unmatched pixels among them, are NaN, as
  ROS organized clouds mark them.

  ## Options

    * `:decimation` (`4`) — depth pixels per cloud point in each
      direction, 1 to 16; fixed in the build.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.Pair

  @min_depth_m 0.05
  @max_depth_m 20.0
  @max_decimation 16

  @option_specs [
    decimation: %{
      type: :integer,
      range: {1, @max_decimation},
      step: 1,
      applies: :build,
      description: "Depth pixels per cloud point in each direction"
    }
  ]

  @defaults %{decimation: 4}

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Unprojects the depth into a decimated point cloud."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Turns the depth image into 3D points in the left camera's frame, for ROS 2 tools " <>
        "such as maps and obstacle avoidance. decimation, fixed in the build, keeps one pixel " <>
        "out of decimation × decimation: a higher value makes a lighter cloud with less " <>
        "detail. Points too near, too far or without depth are left empty, as ROS expects."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    with {:ok, %{decimation: decimation}} <- Check.init_settings(@option_specs, @defaults, opts),
         do: {:ok, decimation}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:depth_m]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:cloud, :cloud_points, :cloud_size]

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "point_cloud"

  @impl VisionCore.Stereo.NxStage
  def native_constants, do: %{min_depth_m: @min_depth_m, max_depth_m: @max_depth_m}

  @impl VisionCore.Stereo.NxStage
  def params(_state, context) do
    {cx, cy} = context.principal_point
    %{focal_length_px: context.focal_length_px, cx: cx, cy: cy}
  end

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, decimation) do
    {grid, kept} =
      NxStereo.Depth.point_cloud(tensors.depth_m, params.focal_length_px, params.cx, params.cy,
        decimation: decimation,
        min_depth_m: @min_depth_m,
        max_depth_m: @max_depth_m
      )

    tensors
    |> Map.put(:cloud_grid, grid)
    |> Map.put(:cloud_points, kept)
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _decimation) do
    {height, width, 3} = Nx.shape(outputs.cloud_grid)

    %{
      pair
      | cloud: Nx.to_binary(outputs.cloud_grid),
        cloud_points: Nx.to_number(outputs.cloud_points),
        cloud_size: {height, width}
    }
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(decimation), do: %{decimation: decimation}
end
