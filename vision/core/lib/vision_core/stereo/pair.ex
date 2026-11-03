defmodule VisionCore.Stereo.Pair do
  @moduledoc """
  One left/right pair: the two frames submitted to
  `VisionCore.Stereo.Pipeline`, and everything its stages derive from
  them. Each field is filled by the stage that `provides/0` it (see
  `VisionCore.Stereo.Stage`); the pipeline publishes the finished pair
  as `{:stereo_pair, %Pair{}}` (`VisionCore.Outputs`).

    * `:left_frame`, `:right_frame` — the submitted `Camera.Frame`s,
      each with its camera's frame id: the disparity, depth and point
      cloud are in the left one's (`frame_id/1`).
    * `:geometry` — the pipeline's `t:VisionCore.Stereo.Stage.context/0`
      at the time: capture size, calibration, focal length, baseline
      and principal point.
    * `:left`, `:right` — `u8` `{height, width}` tensors: decoded, then
      rectified, so a point lies on the same row in each. What a
      consumer that needs pixels rather than depth (the detector) uses.
    * `:disparity` — the matcher's disparity, an `f32` tensor in pixels
      times `:disparity_scale`: positive where matched, -1 where
      unmatched. A stage tests `> 0` for a match.
    * `:disparity_range` — `%{min_disparity: _, num_disparities: _,
      block_size: _, block_height: _}`, the matcher's search and the
      width and height of its matching window, `block_height`
      `block_size` when left out; see `disparity_bounds/1` and
      `valid_window/1`.
    * `:disparity_bytes` — 32-bit float disparity in pixels, row-major,
      what `stereo_msgs/DisparityImage.image` carries. Unmatched pixels
      stay below the minimum disparity rather than clamped to 0.
    * `:depth` — 16-bit depth in millimetres, row-major, 0 where there
      is no measurement, unmatched or beyond the 65535 mm 16 bits hold:
      the ROS depth-image convention, at half the bytes of 32-bit metres.
    * `:cloud`, `:cloud_size`, `:cloud_points` — an organized grid of
      `x, y, z` 32-bit float points in the left optical frame, row-major,
      its `{height, width}`, and how many points are measured: the others,
      unmatched pixels among them, are NaN.
    * `:alignment` — how far the right image's rows sit from the left
      one's, in rows: `%{offset_rows: float, band_offset_rows: [float | nil]}`,
      over the whole image and per vertical band from left to right, `nil`
      for a band it cannot measure; `nil` before it is measured, and when
      the whole image cannot be (`VisionCore.Stereo.Stage.RowAlignment`).
    * `:sharpness` — each rectified image's sharpness,
      `%{left: float, right: float}`, comparable between the two
      (`VisionCore.Stereo.Stage.Sharpness`); `nil` before it is measured.
    * `:metrics` — `{name, value, unit}` samples a stage reports for the
      pipeline's log line.
    * `:device_ms` — the time the pair spent in compiled Nx segments, on
      the GPU where they run there, and in native segments, in the
      `stereo_match` Port, less what overlaps the previous pair's, so
      successive pairs' times add up to the time the segments were busy.
  """

  @enforce_keys [:left_frame, :right_frame]
  defstruct [
    :left_frame,
    :right_frame,
    :geometry,
    :left,
    :right,
    :disparity,
    :disparity_range,
    :disparity_bytes,
    :depth,
    :cloud,
    :cloud_size,
    :alignment,
    :sharpness,
    cloud_points: 0,
    disparity_scale: 1.0,
    device_ms: 0.0,
    metrics: []
  ]

  @type t :: %__MODULE__{}

  @doc "The left frame's monotonic capture time, which every output is stamped with."
  @spec capture_ns(t()) :: integer()
  def capture_ns(%__MODULE__{left_frame: frame}), do: frame.capture_ns

  @doc """
  The frame the pair's outputs are in: the left camera's optical frame,
  `nil` when its driver was given none.
  """
  @spec frame_id(t()) :: String.t() | nil
  def frame_id(%__MODULE__{left_frame: frame}), do: frame.frame_id

  @doc "`{width, height}` of the rectified images and the maps derived from them."
  @spec size(t()) :: {pos_integer(), pos_integer()}
  def size(%__MODULE__{left: %Nx.Tensor{} = left}) do
    {height, width} = Nx.shape(left)
    {width, height}
  end

  def size(%__MODULE__{geometry: geometry}), do: {geometry.width, geometry.height}

  @doc "The matcher's search range as `{min, max}` disparity, in pixels."
  @spec disparity_bounds(t()) :: {float(), float()}
  def disparity_bounds(%__MODULE__{disparity_range: range}),
    do: {range.min_disparity / 1.0, (range.min_disparity + range.num_disparities - 1) / 1.0}

  @doc """
  The disparity step `stereo_msgs/DisparityImage` carries as `delta_d`,
  in pixels: 1/16, the sub-pixel step of OpenCV's SGBM, which the
  message's consumers assume. The matcher's parabolic refinement gives
  `f32` fractions, finer than any fixed step.
  """
  @spec disparity_step(t()) :: float()
  def disparity_step(%__MODULE__{}), do: 1 / 16

  @doc """
  `{x, y, width, height}` of the region where disparity is meaningful:
  away from the borders, where the matcher had enough context. The
  search range is left out on the left, the matching window's width on
  the right, and half its height above and below.
  """
  @spec valid_window(t()) :: {integer(), integer(), integer(), integer()}
  def valid_window(%__MODULE__{disparity_range: range} = pair) do
    {width, height} = size(pair)
    search = range.min_disparity + range.num_disparities
    half_height = div(Map.get(range, :block_height, range.block_size), 2)

    {search, half_height, max(width - search - range.block_size, 0),
     max(height - 2 * half_height, 0)}
  end
end
