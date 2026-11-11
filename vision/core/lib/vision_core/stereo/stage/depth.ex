defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns the disparity in pixels into metric depth with
  `NxStereo.Stage.Depth`, and fills the 32-bit float disparity and the
  16-bit millimetre depth from it.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Depth

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
  def provides, do: [:disparity_bytes, :depth, :depth_m]

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    %{
      pair
      | disparity_bytes: Nx.to_binary(outputs.disparity),
        depth: Nx.to_binary(outputs.depth_mm)
    }
  end
end
