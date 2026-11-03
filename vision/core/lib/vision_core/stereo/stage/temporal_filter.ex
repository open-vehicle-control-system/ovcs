defmodule VisionCore.Stereo.Stage.TemporalFilter do
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

    * `:alpha` (`0.4`) — the new value's weight, 0.05 to 1; `1.0` turns
      smoothing off.
    * `:delta` (`2.0`) — the largest change, in pixels, that is smoothed,
      up to 8.
    * `:hold` (`2`) — how many pairs a lost match is held, up to 10; `0`
      turns holding off.

  They change while running.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check

  @max_hold 10
  # The missed count stops here, above the longest hold, so that every hold ends.
  @max_missed 255.0

  @option_specs [
    alpha: %{
      type: :double,
      range: {0.05, 1},
      description:
        "Weight of a new disparity where it agrees with the previous one; 1 turns smoothing off"
    },
    delta: %{
      type: :double,
      range: {0, 8},
      description: "Largest disparity change, in pixels, that is smoothed"
    },
    hold: %{
      type: :integer,
      range: {0, @max_hold},
      description:
        "Pairs a pixel that loses its match keeps its last disparity; 0 turns holding off"
    }
  ]

  @defaults %{alpha: 0.4, delta: 2.0, hold: 2}

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Smooths the disparity over time and holds lost matches briefly."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Smooths the depth over time, so a still scene stays still. Where a pixel's disparity " <>
        "changed by less than delta pixels since the previous pair, it moves only alpha of " <>
        "the way to the new value; a larger change is taken at once, so moving objects and " <>
        "new edges show without lag. A pixel that loses its match keeps its last value for up " <>
        "to hold pairs, which fills holes that come and go. A lower alpha is steadier but " <>
        "slower to follow, and 1.0 turns smoothing off. Watch Jitter under the depth video."

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: {:ok, Map.put(settings, :size, {context.height, context.width})}
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
    matched = Nx.greater(current, 0)
    missed = Nx.select(matched, 0.0, Nx.add(params.missed, 1))

    held =
      Nx.logical_and(
        Nx.logical_not(matched),
        Nx.logical_and(Nx.greater(params.previous, 0), Nx.less_equal(missed, params.hold))
      )

    filtered = Nx.select(held, params.previous, smoothed)

    tensors
    |> Map.put(:disparity, filtered)
    |> Map.put({:carry, :previous}, filtered)
    |> Map.put({:carry, :missed}, Nx.min(missed, @max_missed))
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{alpha: state.alpha, delta: state.delta, hold: state.hold}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) do
    with {:ok, value} <- Check.change_setting(@option_specs, options(state), key, value),
         do: {:ok, %{state | key => value}}
  end

  defp smooth(current, previous, alpha, delta) do
    agree =
      Nx.logical_and(
        Nx.logical_and(Nx.greater(current, 0), Nx.greater(previous, 0)),
        Nx.less_equal(Nx.abs(Nx.subtract(current, previous)), delta)
      )

    blended = Nx.add(Nx.multiply(alpha, current), Nx.multiply(Nx.subtract(1, alpha), previous))
    Nx.select(agree, blended, current)
  end
end
