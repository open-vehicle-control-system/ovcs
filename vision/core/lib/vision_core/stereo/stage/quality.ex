defmodule VisionCore.Stereo.Stage.Quality do
  @moduledoc """
  Measures the disparity on every `:every_n`-th pair (`5`), for the
  pipeline's log line only: the share of matched pixels, the mean and
  spread of their disparity, and the jitter, the mean frame-to-frame
  disparity change over pixels matched in both frames (the matcher's
  noise on a static scene).
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(opts, _context),
    do: {:ok, %{every_n: Keyword.get(opts, :every_n, 5), count: 0, previous: nil}}

  @impl VisionCore.Stereo.Stage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:metrics]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, state) do
    count = state.count + 1

    if rem(count, state.every_n) == 0 do
      metrics = measure(pair.disparity, state.previous, pair.disparity_scale)

      {:ok, %{pair | metrics: pair.metrics ++ metrics},
       %{state | count: count, previous: pair.disparity}}
    else
      {:ok, pair, %{state | count: count}}
    end
  end

  defp measure(disparity, previous, scale) do
    valid_mask = Evision.compare(disparity, 0, Evision.Constant.cv_CMP_GT())
    valid_count = Evision.countNonZero(valid_mask)
    {height, width} = Evision.Mat.shape(disparity)
    pixel_count = height * width
    valid_percent = if pixel_count > 0, do: 100.0 * valid_count / pixel_count, else: 0.0

    {mean_px, standard_deviation_px} =
      if valid_count > 0 do
        {mean, deviation} =
          Evision.meanStdDev(Evision.Mat.as_type(disparity, :f32), mask: valid_mask)

        {first_number(mean) / scale, first_number(deviation) / scale}
      else
        {0.0, 0.0}
      end

    [
      {:valid, valid_percent, "%"},
      {:mean_disp, mean_px, "px"},
      {:std_disp, standard_deviation_px, "px"},
      {:jitter, jitter(disparity, previous, valid_mask, scale), "px"}
    ]
  end

  defp jitter(_current, nil, _mask, _scale), do: 0.0

  defp jitter(current, previous, valid_mask, scale) do
    previous_mask = Evision.compare(previous, 0, Evision.Constant.cv_CMP_GT())
    both_valid = Evision.Mat.bitwise_and(valid_mask, previous_mask)

    case Evision.countNonZero(both_valid) do
      0 ->
        0.0

      _ ->
        delta =
          Evision.absdiff(Evision.Mat.as_type(current, :f32), Evision.Mat.as_type(previous, :f32))

        first_number(Evision.mean(delta, mask: both_valid)) / scale
    end
  end

  defp first_number(%Evision.Mat{} = mat) do
    case Evision.Mat.to_nx(mat) |> Nx.backend_transfer() |> Nx.to_flat_list() do
      [first | _] -> first
      [] -> 0.0
    end
  end

  defp first_number(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0, do: elem(tuple, 0)
  defp first_number(number) when is_number(number), do: number
  defp first_number(_other), do: 0.0
end
