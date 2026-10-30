defmodule VisionCore.Stereo.Stage.Temporal do
  @moduledoc """
  Smooths the disparity over time, on the device. Where a pixel matched
  in this pair and the previous one, within `:delta` pixels of each
  other, it moves `:alpha` of the way from the previous value to the new
  one; elsewhere it takes the new value, so motion and new edges show at
  once. On a still scene this removes most of the frame-to-frame
  flicker the matcher's subpixel estimates have.

  ## Options

    * `:alpha` (`0.4`) — the new value's weight; `1.0` turns the filter
      off.
    * `:delta` (`2.0`) — the largest change, in pixels, that is smoothed.

  Both change while running, as `temporal_alpha` and `temporal_delta`.
  """
  @behaviour VisionCore.Stereo.NxStage

  @option_specs [
    temporal_alpha: %{
      type: :double,
      range: {0.05, 1},
      description:
        "Weight of a new disparity where it agrees with the previous one; 1 turns smoothing off"
    },
    temporal_delta: %{
      type: :double,
      range: {0, 8},
      description: "Largest disparity change, in pixels, that is smoothed"
    }
  ]

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    state = %{
      alpha: Keyword.get(opts, :alpha, 0.4),
      delta: Keyword.get(opts, :delta, 2.0),
      size: {context.height, context.width}
    }

    with {:ok, state} <- validate(state, :alpha, state.alpha),
         do: validate(state, :delta, state.delta)
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def params(state, _context), do: %{alpha: state.alpha, delta: state.delta}

  @impl VisionCore.Stereo.NxStage
  def carry(state, _context), do: %{previous: Nx.broadcast(Nx.f32(-1), state.size)}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    filtered = smooth(tensors.disparity, params.previous, params.alpha, params.delta)

    tensors
    |> Map.put(:disparity, filtered)
    |> Map.put({:carry, :previous}, filtered)
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{temporal_alpha: state.alpha, temporal_delta: state.delta}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, :temporal_alpha, value), do: validate(state, :alpha, value)
  def set_option(state, :temporal_delta, value), do: validate(state, :delta, value)

  defp validate(state, :alpha, value) when is_number(value) and value > 0 and value <= 1,
    do: {:ok, %{state | alpha: value * 1.0}}

  defp validate(state, :delta, value) when is_number(value) and value >= 0,
    do: {:ok, %{state | delta: value * 1.0}}

  defp validate(_state, key, value),
    do: {:error, "temporal #{key} out of range: #{inspect(value)}"}

  defp smooth(current, previous, alpha, delta) do
    agree =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(current, 0), Nx.greater_equal(previous, 0)),
        Nx.less_equal(Nx.abs(Nx.subtract(current, previous)), delta)
      )

    blended = Nx.add(Nx.multiply(alpha, current), Nx.multiply(Nx.subtract(1, alpha), previous))
    Nx.select(agree, blended, current)
  end
end
