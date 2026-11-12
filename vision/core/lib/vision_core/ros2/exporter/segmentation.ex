defmodule VisionCore.Ros2.Exporter.Segmentation do
  @moduledoc """
  The ROS 2 messages of one segmentation pipeline's results
  (`VisionCore.Segmentation.Pipeline`), which `VisionCore.Ros2.Exporter`
  publishes:

    * `<prefix>/<name>/labels` — the label image, a `mono8`
      `sensor_msgs/Image` whose pixels are the class ids of the model's
      output grid over the band of the camera's image it saw, in the
      camera's frame, stamped with the segmented frame's capture time.
    * `<prefix>/<name>/road/points` and `<prefix>/<name>/off_road/points`
      — the stereo points in a road cell and in any other cell, each a
      `sensor_msgs/PointCloud2` of `x`, `y`, `z` in the stereo pair's
      left optical frame, the frame of its depth, stamped with the pair's
      capture time, as its `<prefix>/points` is. The labels and the
      clouds of one result therefore carry different stamps: a consumer
      syncing them needs an approximate-time policy. A result without
      clouds, as without a matched stereo pair, publishes none; one whose
      points all fall outside the band publishes empty ones.

  ## Options

    * `:pipeline` (required) — the segmentation pipeline's name, the
      `<name>` of the topics.
    * `:topic_prefix` (`"stereo"`) — the `<prefix>` of the topics.
    * `:camera` and `:camera_frame_id` (`"<camera>_optical"`) — the
      source camera and its frame, for a frame that carries none.
    * `:cloud_frame_id` (`"<prefix>_left"`) — the stereo left optical
      frame, for a pair that carries none.
  """

  alias Ros2Zenoh.SensorMsgs.Msg.{Image, PointCloud2}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.Stamp

  @default_topic_prefix "stereo"

  @typedoc "A message to publish: its topic, its module and the message."
  @type message :: {String.t(), module(), struct()}

  @typedoc "The topics and the frames of a frame or pair that carries none, from `new/1`."
  @type t :: %{
          labels_topic: String.t(),
          road_topic: String.t(),
          off_road_topic: String.t(),
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
        topic_prefix: @default_topic_prefix
      ])

    pipeline = Keyword.fetch!(options, :pipeline)
    topic_prefix = options[:topic_prefix]

    %{
      labels_topic: "#{topic_prefix}/#{pipeline}/labels",
      road_topic: "#{topic_prefix}/#{pipeline}/road/points",
      off_road_topic: "#{topic_prefix}/#{pipeline}/off_road/points",
      camera_frame_id: options[:camera_frame_id] || "#{options[:camera]}_optical",
      cloud_frame_id: options[:cloud_frame_id] || "#{topic_prefix}_left"
    }
  end

  @doc """
  The messages of the result for `frame`: its label image, then, with
  `clouds`, the road and the off-road points.
  """
  @spec messages(Frame.t(), map(), map() | nil, t()) :: [message()]
  def messages(%Frame{} = frame, labels, clouds, settings) do
    image_header = %Header{
      stamp: Stamp.stamp_from_monotonic(frame.capture_ns),
      frame_id: frame.frame_id || settings.camera_frame_id
    }

    [{settings.labels_topic, Image, label_image(labels, image_header)}] ++
      cloud_messages(clouds, settings)
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
