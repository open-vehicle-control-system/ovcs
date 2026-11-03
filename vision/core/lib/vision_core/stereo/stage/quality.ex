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
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.{NxStage, Pair}

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
  def init(opts, context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts),
         do: {:ok, %{size: {context.height, context.width}}}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:metrics]

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "quality"

  @impl VisionCore.Stereo.NxStage
  def carry(state, _context), do: %{previous: Nx.broadcast(Nx.f32(-1), state.size)}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    current = tensors.disparity

    tensors
    |> Map.put(:quality_sums, sums(current, params.previous))
    |> Map.put({:carry, :previous}, current)
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, %{size: {height, width}}) do
    [matched, total, squares, both, change] = Nx.to_flat_list(outputs.quality_sums)
    mean = total / max(matched, 1)
    variance = max(squares / max(matched, 1) - mean * mean, 0.0)

    metrics = [
      {:matched_percent, 100.0 * matched / (height * width), "%"},
      {:mean_disparity_px, mean, "px"},
      {:spread_px, :math.sqrt(variance), "px"},
      {:jitter_px, change / max(both, 1), "px"}
    ]

    %{pair | metrics: pair.metrics ++ metrics}
  end

  defp sums(current, previous) do
    matched = current |> Nx.greater(0) |> Nx.as_type(:f32)
    both = previous |> Nx.greater(0) |> Nx.as_type(:f32) |> Nx.multiply(matched)
    values = Nx.multiply(current, matched)

    [
      matched,
      values,
      Nx.multiply(values, values),
      both,
      current |> Nx.subtract(previous) |> Nx.abs() |> Nx.multiply(both)
    ]
    |> Nx.stack()
    |> NxStage.image_sums()
  end
end
