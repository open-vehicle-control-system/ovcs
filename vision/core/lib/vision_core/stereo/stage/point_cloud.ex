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
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: NxStereo.Stage.PointCloud.init(Map.to_list(settings), context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.PointCloud

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:depth_m]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:cloud, :cloud_points, :cloud_size]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.PointCloud

  @impl VisionCore.Stereo.NxStage
  defdelegate native_settings(state), to: NxStereo.Stage.PointCloud

  @impl VisionCore.Stereo.NxStage
  defdelegate native_constants, to: NxStereo.Stage.PointCloud

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: NxStereo.Stage.PointCloud

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.PointCloud

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

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{decimation: state.decimation}
end
