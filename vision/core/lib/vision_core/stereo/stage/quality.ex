defmodule VisionCore.Stereo.Stage.Quality do
  @moduledoc """
  Measures the disparity on every pair, for the pipeline's log line: the
  share of matched pixels, the mean and spread of their disparity, and
  the jitter, the mean pair-to-pair disparity change over pixels matched
  in both (the matcher's noise on a still scene). Its sums are taken on
  the device with the other Nx stages, the previous disparity carried
  there; only five numbers come back.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures the share of matched pixels, the disparity spread and its jitter."

  @impl VisionCore.Stereo.NxStage
  def init(_opts, context), do: {:ok, %{size: {context.height, context.width}}}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:metrics]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

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
      {:valid, 100.0 * matched / (height * width), "%"},
      {:mean_disp, mean, "px"},
      {:std_disp, :math.sqrt(variance), "px"},
      {:jitter, change / max(both, 1), "px"}
    ]

    %{pair | metrics: pair.metrics ++ metrics}
  end

  # Five image planes summed by rows first: other layouts compile to slow GPU reductions.
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
    |> Nx.sum(axes: [1])
    |> Nx.sum(axes: [1])
  end
end
