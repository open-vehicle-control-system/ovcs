defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns the disparity in pixels into metric depth with
  `NxStereo.Stage.Depth`, and fills the 32-bit float disparity and the
  16-bit millimetre depth from it.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Turns the disparity into metric depth."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Turns disparity into distance with the focal length and the spacing between the " <>
        "cameras, taken from the calibration: distance = focal length × spacing ÷ disparity. " <>
        "Far points have small disparities, so their distance is the least precise: there, a " <>
        "fraction of a pixel is a large error in metres. It fills the depth image the " <>
        "exporters publish, such as ROS 2's, and detection uses; pixels without a match, or " <>
        "beyond the 65.5 m it holds, have no depth. It has no settings."

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts),
         do: NxStereo.Stage.Depth.init([], context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity_bytes, :depth, :depth_m]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: NxStereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate device_only, to: NxStereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    %{
      pair
      | disparity_bytes: Nx.to_binary(outputs.disparity),
        depth: Nx.to_binary(outputs.depth_mm)
    }
  end
end
