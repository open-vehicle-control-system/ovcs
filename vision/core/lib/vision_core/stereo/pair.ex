defmodule VisionCore.Stereo.Pair do
  @moduledoc """
  One left/right pair: the two frames submitted to
  `VisionCore.Stereo.Pipeline`, and everything its stages derive from
  them. Each field is filled by the stage that `provides/0` it (see
  `VisionCore.Stereo.Stage`); listeners receive the finished pair as
  `{:stereo_pair, %Pair{}}`.

    * `:left_frame`, `:right_frame` — the submitted `Camera.Frame`s.
    * `:geometry` — the pipeline's `t:VisionCore.Stereo.Stage.context/0`
      at the time: capture size, calibration, focal length, baseline
      and principal point.
    * `:left`, `:right` — `u8` `{height, width}` tensors: decoded, then
      rectified, so a point lies on the same row in each. What a
      consumer that needs pixels rather than depth (the detector) uses.
    * `:disparity` — the matcher's disparity, an `f32` tensor in pixels
      times `:disparity_scale`, negative where unmatched.
    * `:disparity_range` — `%{min_disparity: _, num_disparities: _,
      block_size: _}`, the matcher's search; see `disparity_bounds/1`
      and `valid_window/1`.
    * `:disparity_bytes` — 32-bit float disparity in pixels, row-major,
      what `stereo_msgs/DisparityImage.image` carries. Unmatched pixels
      stay below the minimum disparity rather than clamped to 0.
    * `:depth` — 16-bit depth in millimetres, row-major, 0 where there
      is no measurement: the ROS depth-image convention, at half the
      bytes of 32-bit metres.
    * `:cloud`, `:cloud_size`, `:cloud_points` — an organized grid of
      `x, y, z` 32-bit float points in the left optical frame, row-major,
      its `{height, width}`, and how many points are measured: the others,
      unmatched pixels among them, are NaN.
    * `:alignment` — how far the right image's rows sit from the left
      one's, in rows: `%{offset_rows: float, band_offset_rows: [float]}`,
      over the whole image and per vertical band from left to right
      (`VisionCore.Stereo.Stage.RowAlignment`); `nil` before it is measured.
    * `:sharpness` — each rectified image's sharpness,
      `%{left: float, right: float}`, comparable between the two
      (`VisionCore.Stereo.Stage.Sharpness`); `nil` before it is measured.
    * `:metrics` — `{name, value, unit}` samples a stage reports for the
      pipeline's log line.
    * `:device_ms` — the time the pair spent in compiled Nx segments, on
      the GPU where they run there, and in native segments, in the
      `stereo_match` Port.
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

  @doc "The smallest disparity step the disparity encodes, in pixels."
  @spec delta_d(t()) :: float()
  def delta_d(%__MODULE__{disparity_scale: scale}), do: 1.0 / scale

  @doc """
  `{x, y, width, height}` of the region where disparity is meaningful:
  away from the borders, where the matcher had enough context.
  """
  @spec valid_window(t()) :: {integer(), integer(), integer(), integer()}
  def valid_window(%__MODULE__{disparity_range: range} = pair) do
    {width, height} = size(pair)
    search = range.min_disparity + range.num_disparities

    {search, div(range.block_size, 2), max(width - search - range.block_size, 0),
     max(height - range.block_size, 0)}
  end
end
