defmodule VisionCore.Stereo.Stage.PointCloud do
  @moduledoc """
  Unprojects the depth pixel of every `:decimation`-th row and column,
  from the first, into an organized grid of `x, y, z` points in the left
  optical frame, on the device: each point from the pixel it samples.
  Points outside 5 cm to 20 m, unmatched pixels among them, are NaN, as
  ROS organized clouds mark them.

  ## Settings

  `NxStereo.Stage.PointCloud.settings/0` declares them, with their defaults
  and the values they take; those of a type the vision parameters hold
  are this stage's parameters (`VisionCore.Stereo.NxStage`).
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.PointCloud

  alias VisionCore.Stereo.Pair

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
  def provides, do: [:cloud, :cloud_points, :cloud_size]

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    {height, width, 3} = Nx.shape(outputs.cloud_grid)

    %{
      pair
      | cloud: Nx.to_binary(outputs.cloud_grid),
        cloud_points: Nx.to_number(outputs.cloud_points),
        cloud_size: {height, width}
    }
  end
end
