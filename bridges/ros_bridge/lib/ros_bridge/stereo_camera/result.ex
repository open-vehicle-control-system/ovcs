defmodule RosBridge.StereoCamera.Result do
  @moduledoc """
  One stereo-processing output, corresponding to one input pair.

  Backends fill every field. The publisher uses it directly:
  the disparity binary becomes the body of a
  `stereo_msgs/DisparityImage`, the depth binary becomes a
  `sensor_msgs/Image` (32FC1, metres), and the geometric metadata
  (`focal_length`, `baseline`, `valid_*`, …) populates the
  DisparityImage's surrounding scalars.

  ## Fields

    * `:capture_ns` — left frame's monotonic capture timestamp,
      reused for both outgoing message headers so they share a
      stamp (essential for downstream `ApproximateTime` matchers).
    * `:width`, `:height` — disparity / depth image dimensions
      in pixels.
    * `:disparity` — raw 16UC1 pixel bytes, row-major. Each
      value is `actual_disparity_pixels × 16` (ROS convention,
      matching `stereo_image_proc`).
    * `:disparity_step` — bytes per row of the disparity buffer
      (`width × 2` for 16UC1).
    * `:depth` — raw 32FC1 pixel bytes, row-major. Each value is
      the metric distance to that pixel, in metres. NaN for
      pixels with invalid disparity.
    * `:depth_step` — bytes per row of the depth buffer
      (`width × 4` for 32FC1).
    * `:focal_length` — fx in pixels (the camera's focal length
      on the horizontal axis, from the rectified `P` matrix).
    * `:baseline` — distance between the two camera centres,
      in metres.
    * `:min_disparity`, `:max_disparity` — search-range bounds
      used by the backend, in pixels. Goes into DisparityImage.
    * `:delta_d` — disparity quantization step, in pixels.
      For classic SGBM this is 1/16 (the 16UC1 fixed-point
      resolution).
    * `:valid_x`, `:valid_y`, `:valid_w`, `:valid_h` — pixel
      bounding box inside which disparity values are meaningful.
      For SGBM this is the region away from the image borders
      where the matcher had enough context. Goes into
      DisparityImage's `valid_window`.
  """
  @enforce_keys [
    :capture_ns,
    :width,
    :height,
    :disparity,
    :disparity_step,
    :depth,
    :depth_step,
    :focal_length,
    :baseline,
    :min_disparity,
    :max_disparity,
    :delta_d,
    :valid_x,
    :valid_y,
    :valid_w,
    :valid_h
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          capture_ns: integer(),
          width: pos_integer(),
          height: pos_integer(),
          disparity: binary(),
          disparity_step: pos_integer(),
          depth: binary(),
          depth_step: pos_integer(),
          focal_length: float(),
          baseline: float(),
          min_disparity: float(),
          max_disparity: float(),
          delta_d: float(),
          valid_x: non_neg_integer(),
          valid_y: non_neg_integer(),
          valid_w: non_neg_integer(),
          valid_h: non_neg_integer()
        }
end
