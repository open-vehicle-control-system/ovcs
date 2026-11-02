defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns the disparity in pixels into metric depth, `Z = f × B / d`:
  fills the 32-bit float disparity and the 16-bit millimetre depth, and
  gives the stages after it in the same segment the depth in metres
  (`:depth_m`); unmatched pixels carry no depth. The focal length and
  baseline are inputs, so a reloaded calibration needs no new compiled
  module.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Turns the disparity into metric depth."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Turns disparity into distance with the focal length and the spacing between the " <>
        "cameras, taken from the calibration: distance = focal length × spacing ÷ disparity. " <>
        "Far points have small disparities, so their distance is the least precise: there, a " <>
        "fraction of a pixel is a large error in metres. It fills the depth image sent to ROS " <>
        "2 and used by detection; pixels without a match have no depth. It has no settings."

  @impl VisionCore.Stereo.NxStage
  def init(_opts, _context), do: {:ok, nil}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity_bytes, :depth, :depth_m]

  @impl VisionCore.Stereo.NxStage
  def params(_state, context),
    do: %{focal_length_px: context.focal_length_px, baseline_m: context.baseline_m}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    {depth_mm, depth_m} =
      NxStereo.Depth.depth(tensors.disparity, params.focal_length_px, params.baseline_m)

    tensors |> Map.put(:depth_mm, depth_mm) |> Map.put(:depth_m, depth_m)
  end

  @impl VisionCore.Stereo.NxStage
  def device_only, do: [:depth_m]

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    %{
      pair
      | disparity_bytes: Nx.to_binary(outputs.disparity),
        depth: Nx.to_binary(outputs.depth_mm)
    }
  end
end
