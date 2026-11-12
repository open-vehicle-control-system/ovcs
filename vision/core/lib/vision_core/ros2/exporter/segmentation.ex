defmodule VisionCore.Ros2.Exporter.Segmentation do
  @moduledoc """
  The ROS 2 messages of one segmentation pipeline's results
  (`VisionCore.Segmentation.Pipeline`), which `VisionCore.Ros2.Exporter`
  publishes:

    * `<prefix>/<name>/labels` — the label image, a `mono8`
      `sensor_msgs/Image` whose pixels are the class ids of the model's
      output grid over the band of the camera's image it saw, in the
      camera's frame, stamped with the segmented frame's capture time.
    * `<prefix>/<name>/camera_info` — with each label image and under its
      header, the `sensor_msgs/CameraInfo` that places it on the camera:
      the image's sibling, where `image_transport` looks for it.
    * `<prefix>/<name>/road/points` and `<prefix>/<name>/off_road/points`
      — the stereo points in a road cell and in any other cell, each a
      `sensor_msgs/PointCloud2` of `x`, `y`, `z` in the stereo pair's
      left optical frame, the frame of its depth, stamped with the pair's
      capture time, as its `<prefix>/points` is. The labels and the
      clouds of one result therefore carry different stamps: a consumer
      syncing them needs an approximate-time policy. A result without
      clouds, as without a matched stereo pair, publishes none; one whose
      points all fall outside the band publishes empty ones.

  ## The label image's camera info

  It is the camera's, as `VisionCore.Ros2.Exporter.Camera` publishes it
  for the frame's size, mapped onto the label grid: a camera pixel `u`
  of the band `{x, y, w, h}` is the label pixel
  `u' = (u − x + ½) · W / w − ½`, which puts each cell's centre on its
  pixel, as the pipeline's cell rule does, and `v` likewise with `H / h`.
  Both distortion models distort before the camera matrix, so the
  mapping changes the intrinsics only: `K' = S · K` and `P' = S · P`, `S`
  that affine map, `D`, `R` and the distortion model unchanged, the size
  `W × H`, no `roi` or binning. Without a calibration, or with one of
  another aspect ratio than the frame's, the camera info is empty but
  for its size, as `VisionCore.Ros2.Exporter.Camera`'s is.

  ## Options

    * `:pipeline` (required) — the segmentation pipeline's name, the
      `<name>` of the topics.
    * `:topic_prefix` (`"stereo"`) — the `<prefix>` of the topics.
    * `:camera` and `:camera_frame_id` (`"<camera>_optical"`) — the
      source camera and its frame, for a frame that carries none.
    * `:calibration` (`nil`) — the camera's
      `VisionCore.Ros2.CameraCalibration`.
    * `:cloud_frame_id` (`"<prefix>_left"`) — the stereo left optical
      frame, for a pair that carries none.
  """

  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, Image, PointCloud2}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.{CameraCalibration, Stamp}

  @default_topic_prefix "stereo"

  @typedoc "A message to publish: its topic, its module and the message."
  @type message :: {String.t(), module(), struct()}

  @typedoc """
  The topics, the source camera and its calibration, and the frames of a
  frame or pair that carries none, from `new/1`.
  """
  @type t :: %{
          labels_topic: String.t(),
          camera_info_topic: String.t(),
          road_topic: String.t(),
          off_road_topic: String.t(),
          camera: atom() | nil,
          calibration: CameraCalibration.t() | nil,
          camera_frame_id: String.t(),
          cloud_frame_id: String.t()
        }

  @doc "The topics and frames of the segmentation `options`; see the module doc."
  @spec new(keyword()) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [
        :pipeline,
        :camera,
        :camera_frame_id,
        :cloud_frame_id,
        :calibration,
        topic_prefix: @default_topic_prefix
      ])

    pipeline = Keyword.fetch!(options, :pipeline)
    topic_root = "#{options[:topic_prefix]}/#{pipeline}"

    %{
      labels_topic: "#{topic_root}/labels",
      camera_info_topic: "#{topic_root}/camera_info",
      road_topic: "#{topic_root}/road/points",
      off_road_topic: "#{topic_root}/off_road/points",
      camera: options[:camera],
      calibration: options[:calibration],
      camera_frame_id: options[:camera_frame_id] || "#{options[:camera]}_optical",
      cloud_frame_id: options[:cloud_frame_id] || "#{options[:topic_prefix]}_left"
    }
  end

  @doc """
  The messages of the result for `frame`: its label image and its camera
  info, then, with `clouds`, the road and the off-road points.
  """
  @spec messages(Frame.t(), map(), map() | nil, t()) :: [message()]
  def messages(%Frame{} = frame, labels, clouds, settings) do
    image_header = %Header{
      stamp: Stamp.stamp_from_monotonic(frame.capture_ns),
      frame_id: frame.frame_id || settings.camera_frame_id
    }

    [
      {settings.labels_topic, Image, label_image(labels, image_header)},
      {settings.camera_info_topic, CameraInfo,
       camera_info(settings.calibration, frame, labels, image_header)}
    ] ++ cloud_messages(clouds, settings)
  end

  defp label_image(labels, header) do
    %Image{
      header: header,
      height: labels.height,
      width: labels.width,
      encoding: "mono8",
      is_bigendian: 0,
      step: labels.width,
      data: labels.data
    }
  end

  defp camera_info(nil, _frame, labels, header), do: empty_camera_info(labels, header)

  defp camera_info(calibration, %Frame{width: width, height: height}, labels, header) do
    if CameraCalibration.proportional?(calibration, width, height),
      do:
        grid_camera_info(
          CameraCalibration.resample_to(calibration, width, height),
          labels,
          header
        ),
      else: empty_camera_info(labels, header)
  end

  defp empty_camera_info(labels, header),
    do: %CameraInfo{header: header, width: labels.width, height: labels.height}

  defp grid_camera_info(calibration, %{band: {x, y, w, h}} = labels, header) do
    {sx, sy} = {labels.width / w, labels.height / h}
    to_grid = [sx, 0.0, (0.5 - x) * sx - 0.5, 0.0, sy, (0.5 - y) * sy - 0.5, 0.0, 0.0, 1.0]

    CameraCalibration.camera_info(
      calibration,
      header,
      labels.width,
      labels.height,
      multiply(to_grid, calibration.camera_matrix)
    )
  end

  defp multiply([a0, a1, a2, a3, a4, a5, a6, a7, a8], [b0, b1, b2, b3, b4, b5, b6, b7, b8]) do
    [
      a0 * b0 + a1 * b3 + a2 * b6,
      a0 * b1 + a1 * b4 + a2 * b7,
      a0 * b2 + a1 * b5 + a2 * b8,
      a3 * b0 + a4 * b3 + a5 * b6,
      a3 * b1 + a4 * b4 + a5 * b7,
      a3 * b2 + a4 * b5 + a5 * b8,
      a6 * b0 + a7 * b3 + a8 * b6,
      a6 * b1 + a7 * b4 + a8 * b7,
      a6 * b2 + a7 * b5 + a8 * b8
    ]
  end

  defp cloud_messages(nil, _settings), do: []

  defp cloud_messages(clouds, settings) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(clouds.capture_ns),
      frame_id: clouds.frame_id || settings.cloud_frame_id
    }

    [
      {settings.road_topic, PointCloud2, cloud(clouds.road, header)},
      {settings.off_road_topic, PointCloud2, cloud(clouds.off_road, header)}
    ]
  end

  # Only measured points, so none is NaN.
  defp cloud(points, header) do
    width = div(byte_size(points), PointCloud2.point_step())

    %PointCloud2{
      header: header,
      height: 1,
      width: width,
      fields: PointCloud2.xyz_fields(),
      is_bigendian: 0,
      point_step: PointCloud2.point_step(),
      row_step: width * PointCloud2.point_step(),
      data: points,
      is_dense: 1
    }
  end
end
