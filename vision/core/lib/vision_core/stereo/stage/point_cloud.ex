defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects one depth pixel every `:decimation` (`4`, 1 to 16) in each
  direction into an organized grid of `x, y, z` points in the left
  optical frame, on the device. Points outside 5 cm to 20 m, unmatched
  pixels among them, are NaN, as ROS organized clouds mark them.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @min_depth_m 0.05
  @max_depth_m 20.0
  @max_decimation 16

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Unprojects the depth into a decimated point cloud."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    case Keyword.get(opts, :decimation, 4) do
      decimation when decimation in 1..@max_decimation//1 ->
        {:ok, decimation}

      decimation ->
        {:error,
         "decimation must be an integer from 1 to #{@max_decimation}, got #{inspect(decimation)}"}
    end
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs do
    [
      decimation: %{
        type: :integer,
        range: {1, @max_decimation},
        step: 1,
        applies: :build,
        description: "Depth pixels per cloud point in each direction"
      }
    ]
  end

  @impl VisionCore.Stereo.NxStage
  def options(decimation), do: %{decimation: decimation}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:depth_m]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:cloud, :cloud_points, :cloud_size]

  @impl VisionCore.Stereo.NxStage
  def params(_state, context) do
    {cx, cy} = context.principal_point
    %{focal_length_px: context.focal_length_px, cx: cx, cy: cy}
  end

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, decimation) do
    # NaN depth unprojects to a NaN point: x and y scale with z.
    in_range =
      Nx.logical_and(
        Nx.greater(tensors.depth_m, @min_depth_m),
        Nx.less(tensors.depth_m, @max_depth_m)
      )

    depth_m = Nx.select(in_range, tensors.depth_m, Nx.Constants.nan(:f32))

    grid =
      NxStereo.Depth.cloud_grid(
        depth_m,
        params.focal_length_px,
        params.cx,
        params.cy,
        decimation
      )

    tensors
    |> Map.put(:cloud_grid, grid)
    |> Map.put(:cloud_points, total(Nx.logical_not(Nx.is_nan(grid[[.., .., 2]]))))
  end

  # Rows, then their sums: IREE's Vulkan reduction of a whole grid runs on one thread.
  defp total(kept), do: kept |> Nx.as_type(:s32) |> Nx.sum(axes: [1]) |> Nx.sum()

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
end
