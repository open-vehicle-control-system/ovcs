defmodule VisionCore.Stereo.Stage.RowAlignment do
  @moduledoc """
  Measures how well the rectified images line up: a point should sit on
  the same row in both, and a calibration that no longer fits the
  cameras breaks that first.

  On the device, every matched pixel is compared with the right image at
  its disparity on the rows 2 above to 2 below its own, and the absolute
  differences are summed per vertical band of the image. On the CPU the
  lowest sum of each band, refined between its neighbours, is the row
  offset there: positive when the right image's match sits lower. The
  pair's `:alignment` holds the offset over the whole image and per band,
  from left to right; offsets that change across the bands are a
  rotation. It is also reported as the `align_rows` metric.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @bands 4
  @reach 2
  @row_step 4

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures the row offset between the rectified images."

  @impl VisionCore.Stereo.NxStage
  def init(_opts, context), do: {:ok, %{size: {context.height, context.width}}}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right, :disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:alignment, :metrics]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, _state) do
    Map.put(tensors, :alignment_sums, band_sums(tensors.left, tensors.right, tensors.disparity))
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    {costs, counts} =
      outputs.alignment_sums
      |> Nx.to_list()
      |> Enum.map(&Enum.split(&1, 2 * @reach + 1))
      |> Enum.unzip()

    counts = List.flatten(counts)
    total = costs |> Enum.zip_with(& &1) |> Enum.map(&Enum.sum/1)
    offset = offset(total)
    alignment = %{offset_rows: offset, band_offset_rows: Enum.map(costs, &offset/1)}

    if Enum.sum(counts) > 0 do
      %{pair | alignment: alignment, metrics: pair.metrics ++ [{:align_rows, offset, "rows"}]}
    else
      pair
    end
  end

  # The lowest-cost row offset, refined by a parabola through its neighbours.
  defp offset(costs) do
    {lowest, index} = costs |> Enum.with_index() |> Enum.min_by(&elem(&1, 0))

    if index in 1..(2 * @reach - 1) do
      {before, next} = {Enum.at(costs, index - 1), Enum.at(costs, index + 1)}
      curvature = before - 2 * lowest + next
      shift = if curvature > 0, do: (before - next) / (2 * curvature), else: 0.0
      index - @reach + shift
    else
      (index - @reach) * 1.0
    end
  end

  # Per band, the summed |left - right| per row offset on sampled rows, then the matched count.
  defp band_sums(left, right, disparity) do
    {height, width} = Nx.shape(left)
    sample = &Nx.slice(&1, [0, 0], [height, width], strides: [@row_step, 1])
    {left, disparity} = {sample.(left), sample.(disparity)}
    sampled_height = Nx.axis_size(left, 0)
    matched = Nx.greater_equal(disparity, 0)
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

    # Rows first: summing a band's columns first needs more GPU shared memory than there is.
    Nx.stack(differences ++ [matched])
    |> Nx.slice([0, 0, 0], [planes, sampled_height, band_width * @bands])
    |> Nx.reshape({planes, sampled_height, @bands, band_width})
    |> Nx.sum(axes: [1])
    |> Nx.sum(axes: [2])
    |> Nx.transpose()
  end
end
