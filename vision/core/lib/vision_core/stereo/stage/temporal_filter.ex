defmodule VisionCore.Stereo.Stage.TemporalFilter do
  @moduledoc """
  Smooths the disparity over time, on the device. Where a pixel matched
  in this pair and the previous one, within `:delta` pixels of each
  other, it moves `:alpha` of the way from the previous value to the new
  one; elsewhere it takes the new value. A change within `:delta` is
  therefore smoothed, and lags: a disparity that changes steadily by up
  to `alpha × delta` pixels a pair trails the matcher's by
  `(1 - alpha) / alpha` pairs, so an object approaching slowly reads
  farther than it is. Only a change beyond `:delta`, such as a new edge,
  shows at once. A pixel that loses its match keeps its last disparity
  for up to `:hold` pairs. On a still scene this removes most of the
  flicker the matcher's subpixel estimates have, and the holes of pixels
  whose match comes and goes.

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
        "changed by at most delta pixels since the previous pair, it moves only alpha of the " <>
        "way to the new value. Small changes therefore show late: an object approaching or " <>
        "moving away slowly reads where it was (1 − alpha) ÷ alpha pairs earlier. A lower " <>
        "alpha is steadier but lags more, and 1.0 turns smoothing off. Only a larger change, " <>
        "such as a new edge, is taken at once. A pixel that loses its match keeps its last " <>
        "value for up to hold pairs, which fills holes that come and go. Watch Jitter under " <>
        "the depth video."

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: NxStereo.Stage.TemporalFilter.init(Map.to_list(settings), context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate native_constants, to: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate carry(state, context), to: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.TemporalFilter

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{alpha: state.alpha, delta: state.delta, hold: state.hold}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) do
    with {:ok, value} <- Check.change_setting(@option_specs, options(state), key, value),
         do: {:ok, %{state | key => value}}
  end
end
