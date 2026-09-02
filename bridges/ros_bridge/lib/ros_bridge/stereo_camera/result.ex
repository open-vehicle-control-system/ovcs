defmodule RosBridge.StereoCamera.Result do
  @moduledoc """
  One stereo-processing output, corresponding to one input pair.

  Backends fill every field. The publisher uses it directly:
  the disparity binary becomes the body of a
  `stereo_msgs/DisparityImage`, the depth binary becomes a
  `sensor_msgs/Image` (16UC1, millimetres), and the geometric metadata
  (`focal_length`, `baseline`, `valid_*`, …) populates the
  DisparityImage's surrounding scalars.

  ## Fields

    * `:capture_ns` — left frame's monotonic capture timestamp,
      reused for both outgoing message headers so they share a
      stamp (essential for downstream `ApproximateTime` matchers).
    * `:width`, `:height` — disparity / depth image dimensions
      in pixels.
    * `:disparity` — raw 32FC1 pixel bytes, row-major. Each value
      is a disparity in true pixels, which is what
      `stereo_msgs/DisparityImage.image` carries (and what
      `stereo_image_proc` publishes). Pixels with no match come
      through below `:min_disparity` — the convention consumers
      filter on — rather than clamped to 0.
    * `:disparity_step` — bytes per row of the disparity buffer
      (`width × 4` for 32FC1).
    * `:depth` — raw 16UC1 pixel bytes, row-major. Each value is
      the metric distance to that pixel, in **millimetres**, 0 for
      pixels with invalid disparity (the ROS depth-image "no
      measurement" convention). uint16 mm rather than float32 m
      because it halves the payload, and two full-size float images
      per frame could not share one Zenoh session — the second one
      published was dropped down to ~1.2 Hz. 1 mm over 65 m is well
      past what a 90 mm baseline resolves.
    * `:depth_step` — bytes per row of the depth buffer
      (`width × 2` for 16UC1).
    * `:cloud` — packed `x, y, z` float32 points in the depth image's
      optical frame, or `nil` when cloud generation is off. Invalid
      pixels are dropped rather than encoded, so this is a dense
      buffer of real measurements.
    * `:cloud_points` — how many points `:cloud` holds.
    * `:focal_length` — fx in pixels (the camera's focal length
      on the horizontal axis, from the rectified `P` matrix).
    * `:baseline` — distance between the two camera centres,
      in metres.
    * `:min_disparity`, `:max_disparity` — search-range bounds
      used by the backend, in pixels. Goes into DisparityImage.
    * `:delta_d` — disparity quantization step, in pixels. For
      classic SGBM this is 1/16: the values are floats now, but they
      were derived from OpenCV's ×16 fixed point, so that remains
      the smallest representable increment.
    * `:left_rectified` — the rectified left image as an Evision
      `Mat`, before CLAHE. Carried so a consumer that needs pixels
      rather than depth (the Hailo detector) does not have to decode
      and rectify the frame a second time. A `Mat` is a refcounted
      NIF resource, so passing it between processes costs a pointer,
      not a copy.
    * `:depth_m` — the same depth as `:depth`, but as a float32 `Mat`
      in **metres** rather than packed uint16 millimetres. This is
      what makes a 2D detection into a 3D one: the detector takes a
      median over the box and gets a distance in the units the rest
      of the geometry is already in.
    * `:principal_point` — `{cx, cy}` in pixels, from the rectified
      `P` matrix at the resolution actually published. Needed by
      anything unprojecting a pixel to metres; the image centre is a
      close-enough-looking substitute that silently biases every
      position.
    * `:rectification_map_left` — OpenCV's fixed-point `CV_16SC2`
      map for the left camera, or `nil` when uncalibrated. Carried so
      a consumer can map a rectified pixel *back* to the raw image —
      which is what lets detection boxes be drawn on the `image_raw`
      stream the bridge already publishes, instead of adding a second
      rectified stream to the wire.
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
    :valid_h,
    :cloud,
    :cloud_points
  ]

  # Not enforced: a backend that has no pixels to hand on (or a test
  # building a Result by hand) should not be forced to invent them.
  defstruct @enforce_keys ++
              [
                left_rectified: nil,
                depth_m: nil,
                principal_point: nil,
                rectification_map_left: nil
              ]

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
          valid_h: non_neg_integer(),
          cloud: binary() | nil,
          cloud_points: non_neg_integer(),
          left_rectified: Evision.Mat.t() | nil,
          depth_m: Evision.Mat.t() | nil,
          principal_point: {float(), float()} | nil,
          rectification_map_left: Evision.Mat.t() | nil
        }
end
