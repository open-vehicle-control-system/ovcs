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

  @bands 4
  @reach 2
  @row_step 4
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
  def init(opts, _context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts), do: {:ok, nil}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right, :disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:alignment, :metrics]

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "row_alignment"

  @impl VisionCore.Stereo.NxStage
  def native_constants, do: %{bands: @bands, reach: @reach, row_step: @row_step}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, _state) do
    sums =
      Diagnostics.row_alignment_sums(tensors.left, tensors.right, tensors.disparity,
        bands: @bands,
        reach: @reach,
        row_step: @row_step
      )

    Map.put(tensors, :alignment_sums, sums)
  end

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
