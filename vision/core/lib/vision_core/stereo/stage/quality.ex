defmodule VisionCore.Stereo.Stage.Quality do
  @moduledoc """
  Measures the disparity on every pair, for the pipeline's log line: the
  share of matched pixels, the mean and spread of their disparity, and
  the jitter, the mean pair-to-pair disparity change over pixels matched
  in both (the matcher's noise on a still scene). A pixel is matched
  where its disparity is positive. Its sums are taken on the device with
  the other Nx stages, the previous disparity carried there; only five
  numbers come back.

  It measures the disparity it is given. In the default stages that is
  the final one, after `VisionCore.Stereo.Stage.TemporalFilter`, whose
  held matches raise the matched share and whose smoothing lowers the
  jitter; with that stage's `:alpha` at 1 and `:hold` at 0, it measures
  the matcher alone.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Quality

  alias NxStereo.Diagnostics
  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures the share of matched pixels, the disparity spread and its jitter."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Measures the depth on every pair: the share of pixels matched, their mean disparity " <>
        "and its spread, and the jitter, how much a pixel's disparity changes from one pair " <>
        "to the next. These are the figures under the depth video. Use them when tuning the " <>
        "other steps: a change that raises Matched pixels without raising Jitter is an " <>
        "improvement. They measure the final depth, after the temporal filter, whose hold " <>
        "raises Matched pixels and whose smoothing lowers Jitter: to tune the matching " <>
        "itself, set that filter's alpha to 1 and its hold to 0 first. It has no settings."

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:metrics]

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, %{size: {height, width}}) do
    stats = Diagnostics.disparity_stats(outputs.quality_sums, height * width)

    metrics = [
      {:matched_percent, 100.0 * stats.matched, "%"},
      {:mean_disparity_px, stats.mean_px, "px"},
      {:spread_px, stats.spread_px, "px"},
      {:jitter_px, stats.jitter_px, "px"}
    ]

    %{pair | metrics: pair.metrics ++ metrics}
  end
end
