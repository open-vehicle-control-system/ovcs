defmodule VisionCore.Stereo.Stage.Clahe do
  @moduledoc """
  Local contrast equalisation of the images to match, which gives the
  matcher's cost more signal in low-texture regions. The rectified
  images themselves are left as they are for consumers.

  ## Options

    * `:clahe` (`true`) — on or off, also at runtime.
    * `:clahe_clip_limit` (`2.0`), `:clahe_tile_grid_size` (`{8, 8}`).
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(opts, _context) do
    state = %{
      enabled: Keyword.get(opts, :clahe, true),
      clip_limit: Keyword.get(opts, :clahe_clip_limit, 2.0) * 1.0,
      tile_grid_size: Keyword.get(opts, :clahe_tile_grid_size, {8, 8})
    }

    {:ok, Map.put(state, :clahe, create(state))}
  end

  @impl VisionCore.Stereo.Stage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:match_left, :match_right]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, %{enabled: false} = state),
    do: {:ok, %{pair | match_left: pair.left, match_right: pair.right}, state}

  def run(%Pair{} = pair, %{clahe: clahe} = state) do
    {:ok,
     %{
       pair
       | match_left: Evision.CLAHE.apply(clahe, pair.left),
         match_right: Evision.CLAHE.apply(clahe, pair.right)
     }, state}
  end

  @impl VisionCore.Stereo.Stage
  def option_specs do
    [
      clahe: %{type: :bool, description: "Local contrast equalisation before matching"},
      clahe_clip_limit: %{
        type: :double,
        range: {0, 40},
        description: "Contrast limit of the equalisation"
      }
    ]
  end

  @impl VisionCore.Stereo.Stage
  def options(state), do: %{clahe: state.enabled, clahe_clip_limit: state.clip_limit}

  @impl VisionCore.Stereo.Stage
  def set_option(state, :clahe, enabled) when is_boolean(enabled),
    do: {:ok, %{state | enabled: enabled}}

  def set_option(state, :clahe_clip_limit, limit)
      when is_number(limit) and limit > 0 and limit <= 40 do
    state = %{state | clip_limit: limit * 1.0}
    {:ok, %{state | clahe: create(state)}}
  end

  def set_option(_state, key, value),
    do: {:error, "invalid stereo setting #{inspect(key)}: #{inspect(value)}"}

  defp create(state),
    do: Evision.createCLAHE(clipLimit: state.clip_limit, tileGridSize: state.tile_grid_size)
end
