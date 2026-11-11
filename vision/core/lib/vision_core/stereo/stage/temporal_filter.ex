defmodule VisionCore.Stereo.Stage.TemporalFilter do
  @moduledoc """
  Smooths the disparity over time, on the device. Where a pixel matched
  in this pair and the previous one, within `:delta` pixels of each
  other, it moves `:alpha` of the way from the previous value to the new
  one; elsewhere it takes the new value. A change within `:delta` is
  therefore smoothed, and lags: a disparity that changes steadily by up
  to `alpha × delta` pixels a pair trails the matcher's by
  `(1 - alpha) / alpha` pairs, so an object approaching slowly reads
  farther than it is. Only a change beyond `:delta`, such as a new edge,
  shows at once. A pixel that loses its match keeps its last disparity
  for up to `:hold` pairs. On a still scene this removes most of the
  flicker the matcher's subpixel estimates have, and the holes of pixels
  whose match comes and goes.

  ## Settings

  `NxStereo.Stage.TemporalFilter.settings/0` declares them, with their defaults
  and the values they take; those of a type the vision parameters hold
  are this stage's parameters (`VisionCore.Stereo.NxStage`).
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Smooths the disparity over time and holds lost matches briefly."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Smooths the depth over time, so a still scene stays still. Where a pixel's disparity " <>
        "changed by at most delta pixels since the previous pair, it moves only alpha of the " <>
        "way to the new value. Small changes therefore show late: an object approaching or " <>
        "moving away slowly reads where it was (1 − alpha) ÷ alpha pairs earlier. A lower " <>
        "alpha is steadier but lags more, and 1.0 turns smoothing off. Only a larger change, " <>
        "such as a new edge, is taken at once. A pixel that loses its match keeps its last " <>
        "value for up to hold pairs, which fills holes that come and go. Watch Jitter under " <>
        "the depth video."
end
