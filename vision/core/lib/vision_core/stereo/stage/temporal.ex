defmodule VisionCore.Stereo.Stage.Temporal do
  @moduledoc """
  Smooths the disparity over time, on the device. Where a pixel matched
  in this pair and the previous one, within `:delta` pixels of each
  other, it moves `:alpha` of the way from the previous value to the new
  one; elsewhere it takes the new value, so motion and new edges show at
  once. A pixel that loses its match keeps its last disparity for up to
  `:hold` pairs. On a still scene this removes most of the flicker the
  matcher's subpixel estimates have, and the holes of pixels whose match
  comes and goes.

  ## Options

    * `:alpha` (`0.4`) — the new value's weight; `1.0` turns smoothing
      off.
    * `:delta` (`2.0`) — the largest change, in pixels, that is smoothed.
    * `:hold` (`2`) — how many pairs a lost match is held; `0` turns
      holding off.

  They change while running, as `temporal_alpha`, `temporal_delta` and
  `temporal_hold`.
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
    },
    temporal_hold: %{
      type: :integer,
      range: {0, 10},
      description:
        "Pairs a pixel that loses its match keeps its last disparity; 0 turns holding off"
    }
  ]

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    state = %{
      alpha: Keyword.get(opts, :alpha, 0.4),
      delta: Keyword.get(opts, :delta, 2.0),
      hold: Keyword.get(opts, :hold, 2),
      size: {context.height, context.width}
    }

    with {:ok, state} <- validate(state, :alpha, state.alpha),
         {:ok, state} <- validate(state, :delta, state.delta),
         do: validate(state, :hold, state.hold)
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def params(state, _context), do: %{alpha: state.alpha, delta: state.delta, hold: state.hold}

  # `missed`: pairs since the pixel last matched.
  @impl VisionCore.Stereo.NxStage
  def carry(state, _context) do
    %{
      previous: Nx.broadcast(Nx.f32(-1), state.size),
      missed: Nx.broadcast(Nx.f32(0), state.size)
    }
  end

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    current = tensors.disparity
    smoothed = smooth(current, params.previous, params.alpha, params.delta)
    matched = Nx.greater_equal(current, 0)
    missed = Nx.select(matched, 0.0, Nx.add(params.missed, 1))

    held =
      Nx.logical_and(
        Nx.logical_not(matched),
        Nx.logical_and(Nx.greater_equal(params.previous, 0), Nx.less_equal(missed, params.hold))
      )

    filtered = Nx.select(held, params.previous, smoothed)

    tensors
    |> Map.put(:disparity, filtered)
    |> Map.put({:carry, :previous}, filtered)
    |> Map.put({:carry, :missed}, Nx.min(missed, 255.0))
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state),
    do: %{temporal_alpha: state.alpha, temporal_delta: state.delta, temporal_hold: state.hold}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, :temporal_alpha, value), do: validate(state, :alpha, value)
  def set_option(state, :temporal_delta, value), do: validate(state, :delta, value)
  def set_option(state, :temporal_hold, value), do: validate(state, :hold, value)

  defp validate(state, :alpha, value) when is_number(value) and value > 0 and value <= 1,
    do: {:ok, %{state | alpha: value * 1.0}}

  defp validate(state, :delta, value) when is_number(value) and value >= 0,
    do: {:ok, %{state | delta: value * 1.0}}

  defp validate(state, :hold, value) when is_integer(value) and value >= 0,
    do: {:ok, %{state | hold: value}}

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
