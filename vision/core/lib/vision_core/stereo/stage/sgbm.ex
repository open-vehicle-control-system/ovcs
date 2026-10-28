defmodule VisionCore.Stereo.Stage.Sgbm do
  @moduledoc """
  Matches the pair with Evision's `StereoSGBM` (semi-global block
  matching) on the CPU, into a CV_16S disparity in pixels × 16,
  negative where unmatched.

  ## Options

    * `:num_disparities` (64), `:block_size` (5), `:min_disparity`
      (0), `:mode` (`:sgbm_3way`; or `:sgbm`, `:hh`, `:hh4`).
    * `:uniqueness_ratio` (10), `:disp12_max_diff` (2),
      `:pre_filter_cap` (31), `:speckle_window_size` (100),
      `:speckle_range` (32), `:p1` / `:p2` (8 and 32 × `block_size`²)
      — the filtering and smoothness settings; see `option_specs/0`.
  """
  @behaviour VisionCore.Stereo.Stage

  alias Evision.StereoSGBM
  alias VisionCore.Stereo.Pair

  @integer_options %{
    uniqueness_ratio: {0, 100},
    speckle_window_size: {0, 10_000},
    speckle_range: {0, 256},
    p1: {0, 100_000},
    p2: {0, 400_000},
    disp12_max_diff: {-1, 64},
    pre_filter_cap: {1, 63},
    num_disparities: {16, 256}
  }

  @option_descriptions %{
    uniqueness_ratio: "Margin in percent by which the best match must beat the second best",
    speckle_window_size: "Largest region of disparity speckle removed, in pixels (0 disables)",
    speckle_range: "Disparity variation allowed within a connected region",
    p1: "Penalty for a disparity change of 1 between neighbours",
    p2: "Penalty for a larger disparity change between neighbours",
    disp12_max_diff: "Left-right consistency tolerance in pixels (-1 disables)",
    pre_filter_cap: "Clamp of the prefiltered image",
    num_disparities: "Disparity search range in pixels, a multiple of 16; sets the near limit"
  }

  @impl VisionCore.Stereo.Stage
  def init(opts, _context) do
    {:ok,
     %{
       matcher: create_matcher(opts),
       min_disparity: Keyword.get(opts, :min_disparity, 0),
       block_size: Keyword.get(opts, :block_size, 5)
     }}
  end

  @impl VisionCore.Stereo.Stage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:disparity, :disparity_range]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, state) do
    {left, right} = Pair.match_images(pair)

    {:ok,
     %{
       pair
       | disparity: StereoSGBM.compute(state.matcher, left, right),
         disparity_scale: 16.0,
         disparity_range: %{
           min_disparity: state.min_disparity,
           num_disparities: StereoSGBM.getNumDisparities(state.matcher),
           block_size: state.block_size
         }
     }, state}
  end

  @doc false
  def create_matcher(opts) do
    block_size = Keyword.get(opts, :block_size, 5)

    # OpenCV's recipe for one channel; without P1/P2 SGBM has no smoothness penalty.
    default_p1 = 8 * block_size * block_size
    default_p2 = 32 * block_size * block_size

    StereoSGBM.create(
      minDisparity: Keyword.get(opts, :min_disparity, 0),
      numDisparities: Keyword.get(opts, :num_disparities, 64),
      blockSize: block_size,
      mode: mode(Keyword.get(opts, :mode, :sgbm_3way)),
      # The textbook value; lower if too sparse, higher if too noisy.
      uniquenessRatio: Keyword.get(opts, :uniqueness_ratio, 10),
      # 2, not the textbook 1: cameracalibrator rectification is not near-perfect.
      disp12MaxDiff: Keyword.get(opts, :disp12_max_diff, 2),
      preFilterCap: Keyword.get(opts, :pre_filter_cap, 31),
      # speckleRange is in ×16 fixed point.
      speckleWindowSize: Keyword.get(opts, :speckle_window_size, 100),
      speckleRange: Keyword.get(opts, :speckle_range, 32)
    )
    # Evision's create/1 accepts P1 and P2 but drops them: they read
    # back as 0, leaving SGBM without its smoothness penalties.
    |> StereoSGBM.setP1(Keyword.get(opts, :p1, default_p1))
    |> StereoSGBM.setP2(Keyword.get(opts, :p2, default_p2))
  end

  # :sgbm_3way trades a little quality for speed over the 5-path :sgbm.
  defp mode(:sgbm), do: StereoSGBM.cv_MODE_SGBM()
  defp mode(:hh), do: StereoSGBM.cv_MODE_HH()
  defp mode(:sgbm_3way), do: StereoSGBM.cv_MODE_SGBM_3WAY()
  defp mode(:hh4), do: StereoSGBM.cv_MODE_HH4()

  @impl VisionCore.Stereo.Stage
  def option_specs do
    for {key, range} <- @integer_options do
      {key, %{type: :integer, range: range, description: @option_descriptions[key]}}
    end
  end

  @impl VisionCore.Stereo.Stage
  def options(%{matcher: matcher}) do
    %{
      uniqueness_ratio: StereoSGBM.getUniquenessRatio(matcher),
      speckle_window_size: StereoSGBM.getSpeckleWindowSize(matcher),
      speckle_range: StereoSGBM.getSpeckleRange(matcher),
      p1: StereoSGBM.getP1(matcher),
      p2: StereoSGBM.getP2(matcher),
      disp12_max_diff: StereoSGBM.getDisp12MaxDiff(matcher),
      pre_filter_cap: StereoSGBM.getPreFilterCap(matcher),
      num_disparities: StereoSGBM.getNumDisparities(matcher)
    }
  end

  @impl VisionCore.Stereo.Stage
  def set_option(state, key, value) do
    case option_error(key, value) do
      nil -> {:ok, %{state | matcher: apply_option(state.matcher, key, value)}}
      reason -> {:error, reason}
    end
  end

  defp option_error(:num_disparities, value) when is_integer(value) and rem(value, 16) != 0,
    do: "num_disparities must be a multiple of 16, got #{value}"

  defp option_error(key, value) when is_map_key(@integer_options, key) do
    {low, high} = @integer_options[key]

    if is_integer(value) and value >= low and value <= high,
      do: nil,
      else: "#{key} must be an integer within #{low}..#{high}, got #{inspect(value)}"
  end

  defp option_error(key, value),
    do: "unknown or invalid stereo setting #{inspect(key)}: #{inspect(value)}"

  defp apply_option(matcher, :uniqueness_ratio, value),
    do: StereoSGBM.setUniquenessRatio(matcher, value)

  defp apply_option(matcher, :speckle_window_size, value),
    do: StereoSGBM.setSpeckleWindowSize(matcher, value)

  defp apply_option(matcher, :speckle_range, value),
    do: StereoSGBM.setSpeckleRange(matcher, value)

  defp apply_option(matcher, :p1, value), do: StereoSGBM.setP1(matcher, value)
  defp apply_option(matcher, :p2, value), do: StereoSGBM.setP2(matcher, value)

  defp apply_option(matcher, :disp12_max_diff, value),
    do: StereoSGBM.setDisp12MaxDiff(matcher, value)

  defp apply_option(matcher, :pre_filter_cap, value),
    do: StereoSGBM.setPreFilterCap(matcher, value)

  defp apply_option(matcher, :num_disparities, value),
    do: StereoSGBM.setNumDisparities(matcher, value)
end
