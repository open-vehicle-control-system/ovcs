defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns the disparity in pixels into metric depth, `Z = f × B / d`:
  fills the 32-bit float disparity, the 16-bit millimetre depth and the
  metres tensor; unmatched pixels carry no depth. The focal length and
  baseline are inputs, so a reloaded calibration needs no new compiled
  module.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Turns the disparity into metric depth."

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
  def finish(%Pair{} = pair, outputs, _state) do
    %{
      pair
      | disparity_bytes: Nx.to_binary(outputs.disparity),
        depth: Nx.to_binary(outputs.depth_mm),
        depth_m: outputs.depth_m
    }
  end
end
