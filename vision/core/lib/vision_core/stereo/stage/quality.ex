defmodule VisionCore.Stereo.Stage.Quality do
  @moduledoc """
  Measures the disparity on every `:every_n`-th pair (`5`), for the
  pipeline's log line only: the share of matched pixels, the mean and
  spread of their disparity, and the jitter, the mean frame-to-frame
  disparity change over pixels matched in both (the matcher's noise on
  a static scene). A plain stage after the Nx stages, so it does not
  run on the pairs in between; its function is compiled at start with
  the pipeline's `:defn_options`, and so is in the module cache too.
  """
  @behaviour VisionCore.Stereo.Stage

  import Nx.Defn

  alias VisionCore.Stereo.{NxSegment, Pair}

  @impl VisionCore.Stereo.Stage
  def init(opts, context) do
    template = Nx.template({context.height, context.width}, :f32)

    with {:ok, measure} <-
           NxSegment.compile(
             &statistics/2,
             [template, template],
             NxSegment.defn_options(context)
           ) do
      {:ok,
       %{
         every_n: Keyword.get(opts, :every_n, 5),
         count: 0,
         previous: Nx.broadcast(Nx.tensor(-1.0), {context.height, context.width}),
         measure: measure
       }}
    end
  end

  @impl VisionCore.Stereo.Stage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:metrics]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{disparity: disparity} = pair, state) do
    count = state.count + 1

    if rem(count, state.every_n) == 0 do
      [matched, mean, deviation, _both, jitter] =
        state.measure.(disparity, state.previous) |> Nx.to_flat_list()

      metrics = [
        {:valid, 100.0 * matched / Nx.size(disparity), "%"},
        {:mean_disp, mean, "px"},
        {:std_disp, deviation, "px"},
        {:jitter, jitter, "px"}
      ]

      {:ok, %{pair | metrics: pair.metrics ++ metrics},
       %{state | count: count, previous: disparity}}
    else
      {:ok, pair, %{state | count: count}}
    end
  end

  # Matched count, mean, standard deviation, count matched in both, jitter.
  defnp statistics(current, previous) do
    matched = current > 0
    count = total(matched)
    mean = total(Nx.select(matched, current, 0)) / Nx.max(count, 1)
    variance = total(Nx.select(matched, (current - mean) ** 2, 0)) / Nx.max(count, 1)
    both = matched and previous > 0
    both_count = total(both)
    jitter = total(Nx.select(both, Nx.abs(current - previous), 0)) / Nx.max(both_count, 1)

    Nx.stack([count, mean, Nx.sqrt(variance), both_count, jitter])
  end

  # Rows, then their sums: IREE's Vulkan reduction of a whole image is slow.
  defnp(total(values), do: values |> Nx.as_type(:f32) |> Nx.sum(axes: [1]) |> Nx.sum())
end
