defmodule VisionCore.Ros2.Exporter.Stereo do
  @moduledoc """
  The ROS 2 messages of a stereo unit, which `VisionCore.Ros2.Exporter`
  publishes: each side's raw image and intrinsics as the camera drivers
  deliver them, and the disparity, depth and point cloud of each
  `VisionCore.Stereo.Pair` the pipeline finishes. These functions build
  the messages; the exporter sends them, and hands them the function
  that encodes an image to JPEG.

    * **Raw images** on `<topic_prefix>/<side>/image_raw/compressed`,
      and **calibration** on `<topic_prefix>/<side>/camera_info` every
      Nth frame, so late subscribers see it without latched QoS, both
      in the frame id the camera's frame carries.
    * **Stereo outputs**, all stamped with the left frame's capture time
      so consumers can pair them with the raw streams, in the frame id
      it carries (`VisionCore.Stereo.Pair.frame_id/1`):

        * `stereo_msgs/DisparityImage` on `<topic_prefix>/disparity` —
          the canonical topic, and the only one carrying the geometry
          (`f`, `T`, `valid_window`).
        * a 16UC1 `sensor_msgs/Image` of **millimetres** on
          `<topic_prefix>/depth/image_rect`, the ROS depth-image
          convention.
        * `sensor_msgs/CameraInfo` on `<topic_prefix>/depth/camera_info`
          — the left camera's intrinsics at the matching size, from the
          pair's geometry, since the depth image is in the rectified
          left frame. Without a camera_info sibling a viewer cannot
          project the depth image. Its `K` is `P`'s 3x3 block and `D` is
          zero: the image is rectified, so a consumer that reaches for
          `K` instead of `P` still unprojects correctly.
        * `sensor_msgs/PointCloud2` on `<topic_prefix>/points` when the
          pair has points.
        * with `:publish_disparity_image`, the disparity pixels again as
          a bare 32FC1 `sensor_msgs/Image` on
          `<topic_prefix>/disparity/image`, since viewers match on a
          topic's type and will not reach inside the `DisparityImage`
          container.
        * with `:publish_rectified_image`, the rectified left and right
          images as JPEG on `<topic_prefix>/{left,right}/image_rect/compressed`,
          row-aligned, with the depth image's header.

  ## Options

  `VisionCore.Ros2.Exporter` takes `:left`, `:right`, `:width` and
  `:height` from the stereo unit's cameras
  (`VisionCore.Stereo.Supervisor.camera_options/1`); the others are its
  own `stereo:` options.

    * `:topic_prefix` (`"stereo"`) — root of every topic above.
    * `:left`, `:right` — each side's `:calibration_path`, a
      `camera_calibration_parsers` YAML (see
      `VisionCore.Ros2.CameraCalibration`); without one, the side's
      camera info is empty. And its `:frame_id`
      (`<topic_prefix>_left`, `<topic_prefix>_right`), for a frame or
      pair that carries none.
    * `:width` (1280), `:height` (720) — the capture size, which the
      calibration is scaled to and an empty camera info carries.
    * `:camera_info_interval_frames` (30) — camera info every Nth frame.
    * `:publish_raw_images` (`true`) — republish each camera frame. Off
      when the frames already come from those topics, as
      `VisionCore.Ros2.Camera`'s do against a simulator: republishing
      them would feed them back in.
    * `:raw_image_max_hz` (10) — the most raw images a second, per side,
      for grey frames, which are encoded to JPEG; JPEG frames are
      republished as they arrive.
    * `:publish_disparity_image` (`false`) — off by default: a third
      uncompressed image per frame can starve `depth/image_rect` on one
      Zenoh session, so this is a debugging aid to switch on
      deliberately.
    * `:publish_rectified_image` (`false`) — for consumers that pair the
      rectified left image with the depth (RGB-D SLAM), and to see the
      pair as the matcher does. The left one's intrinsics are
      `<topic_prefix>/depth/camera_info`; `<topic_prefix>/left/camera_info`
      describes the raw image.
  """
  require Logger

  alias Ros2Zenoh.SensorMsgs.Msg.{
    CameraInfo,
    CompressedImage,
    Image,
    PointCloud2,
    RegionOfInterest
  }

  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.{CameraCalibration, Stamp}
  alias VisionCore.Stereo.Pair

  @default_topic_prefix "stereo"
  @default_width 1280
  @default_height 720
  @default_camera_info_interval_frames 30
  @default_raw_image_max_hz 10

  @typedoc "A message to publish: its topic, its module and the message."
  @type message :: {String.t(), module(), struct()}

  @typedoc "The JPEG bytes of an image, or why there are none."
  @type encoded :: {:ok, binary()} | {:error, term()}

  @typedoc """
  What the stereo messages are built from: the topics, both sides'
  state and the rates, from `new/1`.
  """
  @type t :: %{
          required(:sides) => %{String.t() => side()},
          optional(atom()) => term()
        }

  @typedoc """
  One side's: its frame id, topics, camera info and calibration path,
  the frames seen and the next raw image's slot.
  """
  @type side :: %{
          frame_id: String.t(),
          image_topic: String.t() | false,
          camera_info_topic: String.t(),
          camera_info: CameraInfo.t(),
          calibration_path: String.t() | nil,
          label: String.t(),
          fallback_width: pos_integer(),
          fallback_height: pos_integer(),
          frame_counter: non_neg_integer(),
          next_image_ms: number() | nil
        }

  @doc "The topics, sides and rates of the stereo `options`; see the module doc."
  @spec new(keyword()) :: t()
  def new(options) do
    prefix = Keyword.get(options, :topic_prefix, @default_topic_prefix)
    width = Keyword.get(options, :width, @default_width)
    height = Keyword.get(options, :height, @default_height)
    publish_raw_images = Keyword.get(options, :publish_raw_images, true)
    publish_rectified_image = Keyword.get(options, :publish_rectified_image, false)

    sides =
      Map.new(["left", "right"], fn label ->
        side_options = Keyword.get(options, String.to_existing_atom(label), [])
        {label, side(label, prefix, side_options, width, height, publish_raw_images)}
      end)

    %{
      sides: sides,
      # The depth and disparity are anchored to the left camera's frame, per ROS convention.
      frame_id: sides["left"].frame_id,
      disparity_topic: "#{prefix}/disparity",
      disparity_image_topic:
        Keyword.get(options, :publish_disparity_image, false) && "#{prefix}/disparity/image",
      depth_topic: "#{prefix}/depth/image_rect",
      depth_camera_info_topic: "#{prefix}/depth/camera_info",
      cloud_topic: "#{prefix}/points",
      rectified_image_topic: publish_rectified_image && "#{prefix}/left/image_rect/compressed",
      right_rectified_image_topic:
        publish_rectified_image && "#{prefix}/right/image_rect/compressed",
      camera_info_interval_frames:
        Keyword.get(options, :camera_info_interval_frames, @default_camera_info_interval_frames),
      raw_image_max_hz: Keyword.get(options, :raw_image_max_hz, @default_raw_image_max_hz)
    }
  end

  @doc """
  One side's state: its frame id, its raw image topic unless
  `publish_raw_images` is off, its camera info topic, and its camera
  info read from its calibration, scaled to `fallback_width` ×
  `fallback_height`.
  """
  @spec side(String.t(), String.t(), keyword(), pos_integer(), pos_integer(), boolean()) :: side()
  def side(label, topic_prefix, side_options, fallback_width, fallback_height, publish_raw_images) do
    calibration_path = Keyword.get(side_options, :calibration_path)

    %{
      frame_id: Keyword.get(side_options, :frame_id, "#{topic_prefix}_#{label}"),
      image_topic: publish_raw_images && "#{topic_prefix}/#{label}/image_raw/compressed",
      camera_info_topic: "#{topic_prefix}/#{label}/camera_info",
      camera_info: load_camera_info(calibration_path, fallback_width, fallback_height, label),
      calibration_path: calibration_path,
      label: label,
      fallback_width: fallback_width,
      fallback_height: fallback_height,
      frame_counter: 0,
      next_image_ms: nil
    }
  end

  @doc """
  `stereo` with each side's camera info read again from its calibration
  file, or from `:left_calibration_path` / `:right_calibration_path` in
  `paths` when given, as after a calibration commit.
  """
  @spec reload(t(), keyword()) :: t()
  def reload(stereo, paths) do
    sides = %{
      "left" => reload_side(stereo.sides["left"], paths[:left_calibration_path]),
      "right" => reload_side(stereo.sides["right"], paths[:right_calibration_path])
    }

    %{stereo | sides: sides}
  end

  @doc "`side` with its camera info read from `calibration_path`, or from its own path when `nil`."
  @spec reload_side(side(), String.t() | nil) :: side()
  def reload_side(side, calibration_path) do
    path = calibration_path || side.calibration_path
    camera_info = load_camera_info(path, side.fallback_width, side.fallback_height, side.label)
    %{side | camera_info: camera_info, calibration_path: path}
  end

  @doc """
  The messages of a camera's `frame` on its `side` of `stereo` at
  `now_ms`, and the side after it: the frame as a raw image when its
  slot is open (`image_slot/4`), encoded by `encode` when it is grey,
  then the side's camera info every Nth frame. A frame that does not
  encode takes its slot all the same, so a failing codec is asked at
  most `:raw_image_max_hz` times a second.
  """
  @spec frame_messages(Frame.t(), side(), t(), number(), (Frame.t() -> encoded())) ::
          {[message()], side()}
  def frame_messages(%Frame{} = frame, side, stereo, now_ms, encode) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(frame.capture_ns),
      frame_id: frame.frame_id || side.frame_id
    }

    {image, side} = raw_image(frame, side, header, now_ms, stereo.raw_image_max_hz, encode)

    camera_info =
      if rem(side.frame_counter, stereo.camera_info_interval_frames) == 0,
        do: [
          {side.camera_info_topic, CameraInfo, raw_camera_info(side.camera_info, header, frame)}
        ],
        else: []

    {image ++ camera_info, %{side | frame_counter: side.frame_counter + 1}}
  end

  defp raw_image(_frame, %{image_topic: false} = side, _header, _now_ms, _max_hz, _encode),
    do: {[], side}

  defp raw_image(frame, side, header, now_ms, max_hz, encode) do
    case image_slot(side.next_image_ms, frame, now_ms, max_hz) do
      {:publish, next_ms} ->
        side = %{side | next_image_ms: next_ms}

        case encode.(frame) do
          {:ok, jpeg} ->
            message = %CompressedImage{header: header, format: "jpeg", data: jpeg}
            {[{side.image_topic, CompressedImage, message}], side}

          {:error, _reason} ->
            {[], side}
        end

      :skip ->
        {[], side}
    end
  end

  @doc """
  Whether to publish `frame` as a raw image at `now_ms`. A JPEG frame is
  always published. A grey frame, which has to be encoded, is published
  once the side's next slot, `next_ms`, has opened: slots are
  `1000 / max_hz` ms apart, so frames on a coarser grid still average
  `max_hz`. Returns the next slot when the frame is published.
  """
  @spec image_slot(number() | nil, Frame.t(), number(), number()) ::
          {:publish, number() | nil} | :skip
  def image_slot(next_ms, %Frame{jpeg: jpeg}, _now_ms, _max_hz) when is_binary(jpeg),
    do: {:publish, next_ms}

  def image_slot(nil, %Frame{}, now_ms, max_hz), do: {:publish, now_ms + 1_000 / max_hz}

  def image_slot(next_ms, %Frame{}, now_ms, max_hz) when now_ms >= next_ms,
    do: {:publish, max(next_ms + 1_000 / max_hz, now_ms)}

  def image_slot(_next_ms, %Frame{}, _now_ms, _max_hz), do: :skip

  @doc """
  Whether publishing `frame` as a raw image at `now_ms` encodes it: it is
  no JPEG frame and its slot is open (`image_slot/4`).
  """
  @spec encodes_image?(Frame.t(), number() | nil, number(), number()) :: boolean()
  def encodes_image?(%Frame{jpeg: jpeg}, _next_ms, _now_ms, _max_hz) when is_binary(jpeg),
    do: false

  def encodes_image?(%Frame{} = frame, next_ms, now_ms, max_hz),
    do: image_slot(next_ms, frame, now_ms, max_hz) != :skip

  @doc "Whether the messages of `pair` hold an image to encode: a rectified image `stereo` publishes."
  @spec encodes_pair?(Pair.t(), t()) :: boolean()
  def encodes_pair?(%Pair{left: left, right: right}, stereo) do
    (is_binary(stereo.rectified_image_topic) and match?(%Nx.Tensor{}, left)) or
      (is_binary(stereo.right_rectified_image_topic) and match?(%Nx.Tensor{}, right))
  end

  # `camera_info` is scaled to the configured capture size; the frame's own size is what it describes.
  defp raw_camera_info(%CameraInfo{} = camera_info, header, %Frame{width: width, height: height}) do
    if camera_info.width == width and camera_info.height == height,
      do: %CameraInfo{camera_info | header: header},
      else: %CameraInfo{camera_info | header: header, width: width, height: height}
  end

  @doc """
  The messages of `pair`, in the order they are published: the
  disparity, the depth, the point cloud, the rectified images, the
  depth's camera info and the bare disparity image, each that `stereo`
  publishes. `encode` turns a rectified image into JPEG bytes.
  """
  @spec pair_messages(Pair.t(), t(), (Nx.Tensor.t() -> encoded())) :: [message()]
  def pair_messages(%Pair{} = pair, stereo, encode) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(Pair.capture_ns(pair)),
      frame_id: Pair.frame_id(pair) || stereo.frame_id
    }

    disparity_image = disparity_image(pair, header)

    [
      {stereo.disparity_topic, DisparityImage, disparity_message(pair, header, disparity_image)},
      {stereo.depth_topic, Image, depth_message(pair, header)}
    ] ++
      cloud_messages(pair, header, stereo.cloud_topic) ++
      rectified_messages(pair, header, stereo, encode) ++
      [
        # Consumers look for camera_info next to the depth image topic.
        {stereo.depth_camera_info_topic, CameraInfo,
         depth_camera_info(pair.geometry.left_calibration, header)}
      ] ++
      if(stereo.disparity_image_topic,
        do: [{stereo.disparity_image_topic, Image, disparity_image}],
        else: []
      )
  end

  defp disparity_image(pair, header) do
    {width, height} = Pair.size(pair)

    %Image{
      header: header,
      height: height,
      width: width,
      # DisparityImage.image is a float disparity image per the spec.
      encoding: "32FC1",
      is_bigendian: 0,
      step: width * 4,
      data: pair.disparity_bytes
    }
  end

  defp disparity_message(pair, header, disparity_image) do
    {valid_x, valid_y, valid_width, valid_height} = Pair.valid_window(pair)
    {min_disparity, max_disparity} = Pair.disparity_bounds(pair)

    %DisparityImage{
      header: header,
      image: disparity_image,
      f: pair.geometry.focal_length_px / 1.0,
      t: pair.geometry.baseline_m / 1.0,
      valid_window: %RegionOfInterest{
        x_offset: valid_x,
        y_offset: valid_y,
        width: valid_width,
        height: valid_height,
        do_rectify: false
      },
      min_disparity: min_disparity,
      max_disparity: max_disparity,
      delta_d: Pair.disparity_step(pair)
    }
  end

  defp depth_message(pair, header) do
    {width, height} = Pair.size(pair)

    %Image{
      header: header,
      height: height,
      width: width,
      # Millimetres in uint16, the ROS depth-image convention. Half
      # the bytes of 32FC1 metres, which is what lets it share a Zenoh
      # session with the disparity image.
      encoding: "16UC1",
      is_bigendian: 0,
      step: width * 2,
      data: pair.depth
    }
  end

  defp cloud_messages(%Pair{cloud: cloud, cloud_points: points} = pair, header, topic)
       when is_binary(topic) and is_binary(cloud) and points > 0 do
    {cloud_height, cloud_width} = pair.cloud_size

    [
      {topic, PointCloud2,
       %PointCloud2{
         header: header,
         height: cloud_height,
         width: cloud_width,
         fields: PointCloud2.xyz_fields(),
         is_bigendian: 0,
         point_step: PointCloud2.point_step(),
         row_step: cloud_width * PointCloud2.point_step(),
         data: cloud,
         # Points without a measurement are NaN.
         is_dense: 0
       }}
    ]
  end

  defp cloud_messages(_pair, _header, _topic), do: []

  defp rectified_messages(pair, header, stereo, encode) do
    for {topic, image} <- [
          {stereo.rectified_image_topic, pair.left},
          {stereo.right_rectified_image_topic, pair.right}
        ],
        is_binary(topic),
        match?(%Nx.Tensor{}, image),
        {:ok, jpeg} <- [encode.(image)],
        do: {topic, CompressedImage, %CompressedImage{header: header, format: "jpeg", data: jpeg}}
  end

  # Rectified image: K is P's 3x3 block and D is zero; see the moduledoc.
  defp depth_camera_info(%CameraCalibration{projection_matrix: projection} = calibration, header) do
    [fx, skew, cx, _tx, _, fy, cy, _ty, _, _, _, _] = projection

    %CameraInfo{
      header: header,
      width: calibration.width,
      height: calibration.height,
      distortion_model: calibration.distortion_model,
      k: [fx, skew, cx, 0.0, fy, cy, 0.0, 0.0, 1.0],
      d: [0.0, 0.0, 0.0, 0.0, 0.0],
      r: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      p: projection
    }
  end

  defp load_camera_info(nil, width, height, side) do
    Logger.warning("#{__MODULE__}: no calibration path for #{side}; publishing empty CameraInfo")

    %CameraInfo{width: width, height: height}
  end

  defp load_camera_info(path, width, height, side) do
    case CameraCalibration.load(path) do
      {:ok, saved_calibration} ->
        # The YAML is saved at the calibration session's resolution; unscaled
        # intrinsics would be wrong by the resolution ratio.
        calibration = CameraCalibration.scale_to(saved_calibration, width, height)

        %CameraInfo{
          width: calibration.width,
          height: calibration.height,
          distortion_model: calibration.distortion_model,
          d: calibration.distortion_coefficients,
          k: calibration.camera_matrix,
          r: calibration.rectification_matrix,
          p: calibration.projection_matrix
        }

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}: cannot read calibration #{inspect(path)} for #{side} (#{inspect(reason)}); " <>
            "publishing empty CameraInfo"
        )

        %CameraInfo{width: width, height: height}
    end
  end
end
