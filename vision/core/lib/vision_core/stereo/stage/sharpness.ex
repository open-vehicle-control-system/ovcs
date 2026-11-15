defmodule VisionCore.Stereo.Stage.Sharpness do
  @moduledoc """
  Measures how sharp each rectified image is, to compare the cameras'
  focus: the mean squared difference between horizontally neighbouring
  pixels over the square of the mean grey, summed on the device.
  Dividing by the brightness keeps an exposure difference between the
  cameras out of it; the absolute value depends on the scene, so it is
  the ratio of the two that tells their focus apart.

  A pair of neighbours counts only where neither pixel is black, 0:
  `VisionCore.Stereo.Stage.Rectification` writes 0 wherever it samples
  outside the camera frame, such as the rows `:right_row_offset` moves
  out of it and the wedges a turned calibration leaves at the image's
  edges. Pixels the camera itself saw as black are left out with them.
  Both means are over the pairs an image counts, and an image without
  any reads 0. The pair's `:sharpness` is `%{left: float, right: float}`.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Sharpness

  alias NxStereo.Diagnostics
  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures each rectified image's sharpness, to compare the cameras' focus."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Measures how sharp each rectified image is. The value itself depends on the scene; " <>
        "what matters is how the two cameras compare, shown as Focus between the videos: " <>
        "how much softer one camera is than the other. Near 0 %, both are focused alike. " <>
        "Far from it, one of them is out of focus, and matching loses detail: refocus that " <>
        "camera. Black pixels are left out, among them the borders rectification leaves " <>
        "where it reaches past a camera's frame. It has no settings."

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:sharpness]

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    %{
      pair
      | sharpness: Diagnostics.sharpness(outputs.sharpness_sums),
        brightness: Diagnostics.brightness(outputs.sharpness_sums)
    }
  end
end
