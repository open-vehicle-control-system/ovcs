defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects one depth pixel every `:decimation` (`4`) in each
  direction into `x, y, z` points in the left optical frame, on the
  device, then keeps the points from 5 cm to 20 m on the CPU, since
  their count varies.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.{Cloud, Pair}

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context), do: {:ok, Keyword.get(opts, :decimation, 4)}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:depth_m]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:cloud, :cloud_points]

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

    Map.put(tensors, :cloud_grid, grid)
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _decimation) do
    {cloud, count} = Cloud.pack_in_range(Nx.to_binary(outputs.cloud_grid))
    %{pair | cloud: cloud, cloud_points: count}
  end
end
