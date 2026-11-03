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
    Map.put(tensors, :alignment_sums, band_sums(tensors.left, tensors.right, tensors.disparity))
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    {band_costs, band_counts} =
      outputs.alignment_sums
      |> Nx.to_list()
      |> Enum.map(&Enum.split(&1, 2 * @reach + 1))
      |> Enum.unzip()

    band_counts = List.flatten(band_counts)
    costs = Enum.zip_with(band_costs, &Enum.sum/1)

    case offset(costs, Enum.sum(band_counts)) do
      nil ->
        pair

      offset ->
        bands = Enum.zip_with(band_costs, band_counts, &offset/2)
        alignment = %{offset_rows: offset, band_offset_rows: bands}
        %{pair | alignment: alignment, metrics: pair.metrics ++ [{:align_rows, offset, "rows"}]}
    end
  end

  # The row offset of the lowest cost, if enough pixels matched and no other offset shares it.
  defp offset(_costs, matched_pixels) when matched_pixels < @min_matched_pixels, do: nil

  defp offset(costs, _matched_pixels) do
    lowest = Enum.min(costs)

    case for({cost, index} <- Enum.with_index(costs), cost == lowest, do: index) do
      [index] -> refine(costs, index)
      _tied -> nil
    end
  end

  # The vertex of the parabola through the lowest cost and its neighbours: unique, it curves up.
  defp refine(costs, index) when index > 0 and index < 2 * @reach do
    [before, lowest, next] = Enum.slice(costs, index - 1, 3)
    index - @reach + (before - next) / (2 * (before - 2 * lowest + next))
  end

  defp refine(_costs, index), do: (index - @reach) * 1.0

  # Per band, the summed |left - right| per row offset on sampled rows, then the matched count.
  defp band_sums(left, right, disparity) do
    {height, width} = Nx.shape(left)
    sample = &Nx.slice(&1, [0, 0], [height, width], strides: [@row_step, 1])
    {left, disparity} = {sample.(left), sample.(disparity)}
    sampled_height = Nx.axis_size(left, 0)
    matched = Nx.greater(disparity, 0)
    columns = Nx.iota({sampled_height, width}, axis: 1)
    rows = Nx.multiply(Nx.iota({sampled_height, width}, axis: 0), @row_step)
    source_columns = columns |> Nx.subtract(Nx.round(disparity)) |> Nx.clip(0, width - 1)

    right = right |> Nx.as_type(:f32) |> Nx.reshape({:auto, 1})
    left = Nx.as_type(left, :f32)
    matched = Nx.as_type(matched, :f32)

    # One plane per row offset, then the counts: a small last axis compiles to one-thread workgroups.
    differences =
      for offset <- -@reach..@reach do
        indices =
          rows
          |> Nx.add(offset)
          |> Nx.clip(0, height - 1)
          |> Nx.multiply(width)
          |> Nx.add(source_columns)
          |> Nx.as_type(:s32)
          |> Nx.new_axis(-1)

        right
        |> Nx.gather(indices)
        |> Nx.reshape({sampled_height, width})
        |> Nx.subtract(left)
        |> Nx.abs()
        |> Nx.multiply(matched)
      end

    band_width = div(width, @bands)
    planes = 2 * @reach + 2

    # Down each column first: summing across a band first needs more GPU shared memory than there is.
    Nx.stack(differences ++ [matched])
    |> Nx.slice([0, 0, 0], [planes, sampled_height, band_width * @bands])
    |> Nx.reshape({planes, sampled_height, @bands, band_width})
    |> Nx.sum(axes: [1])
    |> Nx.sum(axes: [2])
    |> Nx.transpose()
  end
end
