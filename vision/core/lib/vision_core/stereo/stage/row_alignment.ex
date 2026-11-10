defmodule VisionCore.Stereo.Stage.RowAlignment do
  @moduledoc """
  Measures how well the rectified images line up: a point should sit on
  the same row in both, and a calibration that no longer fits the
  cameras breaks that first.

  On the device, the matched pixels of one row in four are compared with
  the right image at their disparity on the rows 2 above to 2 below
  their own, and the absolute differences are summed per vertical band
  of the image. On the CPU the lowest sum of each band, refined between
  its neighbours, is the row offset there: positive when the right
  image's match sits lower. A band where fewer than 64 of those pixels
  matched, or whose lowest sum is not unique, has no offset, `nil`; the
  whole image, whose sums are the bands' together, likewise.

  The pair's `:alignment` holds the offset over the whole image and per
  band, from left to right; offsets that change across the bands are a
  rotation. The offset over the whole image is also reported as the
  `align_rows` metric. Without it, the pair has neither.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias NxStereo.Diagnostics
  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.Pair

  @min_matched_pixels 64

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures the row offset between the rectified images."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Checks that the calibration still fits the cameras. After rectification, a point " <>
        "should be on the same row in both images; this measures how many rows the right " <>
        "image is off, in four bands from left to right, shown as Row alignment between the " <>
        "videos and on this step. A band with too little matched texture to measure shows " <>
        "none. Within half a row is good. A steady larger offset means a camera has moved: " <>
        "auto_row_offset in Rectification follows it, or recalibrate. Offsets that differ " <>
        "from band to band mean a camera has turned, which only a new calibration fixes. It " <>
        "has no settings."

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts),
         do: NxStereo.Stage.RowAlignment.init([], context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.RowAlignment

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right, :disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:alignment, :metrics]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.RowAlignment

  @impl VisionCore.Stereo.NxStage
  defdelegate native_constants, to: NxStereo.Stage.RowAlignment

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.RowAlignment

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    case Diagnostics.row_alignment(outputs.alignment_sums, min_matched: @min_matched_pixels) do
      nil ->
        pair

      alignment ->
        metric = {:align_rows, alignment.offset_rows, "rows"}
        %{pair | alignment: alignment, metrics: pair.metrics ++ [metric]}
    end
  end
end
