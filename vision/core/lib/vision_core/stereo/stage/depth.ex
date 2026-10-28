defmodule VisionCore.Stereo.Stage.Depth do
  @moduledoc """
  Turns disparity into metric depth, `Z = f × B / d`, with the
  rectified focal length and the baseline of the calibration. Fills the
  published 32-bit float disparity, the 16-bit millimetre depth and the
  metres `Mat`; unmatched pixels carry no depth.
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(_opts, context),
    do: {:ok, %{focal_length_px: context.focal_length_px, baseline_m: context.baseline_m}}

  @impl VisionCore.Stereo.Stage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:disparity_bytes, :depth, :depth_m]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{disparity: disparity, disparity_scale: scale} = pair, state) do
    disparity_f32 = Evision.Mat.as_type(disparity, :f32)

    # Unclamped: unmatched pixels stay below min_disparity, as consumers expect.
    disparity_bytes = disparity_f32 |> Evision.divide(scale) |> Evision.Mat.to_binary()

    # Metres to millimetres in the same divide, so there is no extra pass over the image.
    depth_mm =
      Evision.divide(state.focal_length_px * state.baseline_m * scale * 1000.0, disparity_f32)

    invalid_mask = Evision.compare(disparity, 0, Evision.Constant.cv_CMP_LE())
    depth_mm = Evision.Mat.setTo(depth_mm, 0.0, invalid_mask)

    depth =
      depth_mm
      # Saturates: a far reading pins at the ceiling instead of aliasing near.
      |> Evision.Mat.as_type(:u16)
      |> Evision.Mat.to_binary()

    {:ok,
     %{
       pair
       | disparity_bytes: disparity_bytes,
         depth: depth,
         depth_m: Evision.divide(depth_mm, 1000.0)
     }, state}
  end
end
