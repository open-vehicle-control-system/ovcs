defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects one depth pixel every `:decimation` (`4`) in each
  direction into an organized grid of `x, y, z` points in the left
  optical frame, on the device. Points outside 5 cm to 20 m, unmatched
  pixels among them, are NaN, as ROS organized clouds mark them.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @min_depth_m 0.05
  @max_depth_m 20.0

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context), do: {:ok, Keyword.get(opts, :decimation, 4)}

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
    grid =
      NxStereo.Depth.cloud_grid(
        tensors.depth_m,
        params.focal_length_px,
        params.cx,
        params.cy,
        decimation
      )

    z = grid[[.., .., 2]]
    kept = Nx.logical_and(Nx.greater(z, @min_depth_m), Nx.less(z, @max_depth_m))

    tensors
    |> Map.put(
      :cloud_grid,
      Nx.select(Nx.broadcast(Nx.new_axis(kept, -1), grid), grid, Nx.Constants.nan(:f32))
    )
    |> Map.put(:cloud_points, total(kept))
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
