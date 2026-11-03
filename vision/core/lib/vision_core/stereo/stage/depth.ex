defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns the disparity in pixels into metric depth, `Z = f × B / d`:
  fills the 32-bit float disparity and the 16-bit millimetre depth, and
  gives the stages after it in the same segment the depth in metres
  (`:depth_m`). Unmatched pixels have no depth, 0, and neither has the
  16-bit depth beyond the 65535 mm it holds. The focal length and
  baseline are inputs, so a reloaded calibration needs no new compiled
  module.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.Pair

  @max_depth_mm 65_535

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
  def init(opts, _context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts), do: {:ok, nil}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity_bytes, :depth, :depth_m]

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "depth"

  @impl VisionCore.Stereo.NxStage
  def params(_state, context),
    do: %{focal_length_px: context.focal_length_px, baseline_m: context.baseline_m}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    {depth_mm, depth_m} =
      NxStereo.Depth.depth(tensors.disparity, params.focal_length_px, params.baseline_m)

    tensors
    |> Map.put(:depth_mm, clear_beyond_range(depth_mm, depth_m))
    |> Map.put(:depth_m, depth_m)
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

  # NxStereo.Depth saturates at 65535 mm: a depth beyond that is no depth.
  defp clear_beyond_range(depth_mm, depth_m) do
    beyond_range = depth_m |> Nx.multiply(1000) |> Nx.round() |> Nx.greater(@max_depth_mm)
    Nx.select(beyond_range, Nx.u16(0), depth_mm)
  end
end
