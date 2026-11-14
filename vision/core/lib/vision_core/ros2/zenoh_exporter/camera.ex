defmodule VisionCore.Ros2.ZenohExporter.Camera do
  @moduledoc """
  The ROS 2 messages of a camera of its own (`VisionCore.Camera.Unit`),
  which `VisionCore.Ros2.ZenohExporter` publishes. These functions build the
  messages; the exporter sends them, and hands them the function that
  encodes a frame to JPEG.

    * Its **image** as `sensor_msgs/CompressedImage` on
      `<root>/image_raw/compressed`: an RGB or grey frame,
      encoded to JPEG, at most `:raw_image_max_hz` a second, a JPEG
      frame as it arrives (`VisionCore.Ros2.ZenohExporter.Stereo.image_slot/4`);
      and its
      **calibration** as `sensor_msgs/CameraInfo` on
      `<root>/camera_info` every Nth frame, both in the
      frame id the frame carries. The camera info is the calibration's K
      and D, resampled to the frame's size
      (`VisionCore.Ros2.CameraCalibration.resample_to/3`), with R the identity and P = K
      padded with a zero column: the camera is not one of a rectified
      pair. Without a calibration, or with one of another aspect ratio
      than the frames', which is logged, it is empty.
    * Its **video**, each frame of an H.264 output, as
      `foxglove_msgs/CompressedVideo` on `<root>/image_raw/h264`,
      in the frame id the frame carries (`video_message/2`).
    * The **exposure and gain** it applied, as `std_msgs/Float64` on
      `<root>/exposure_us` and `<root>/analogue_gain`
      (`live_messages/2`), for a camera whose driver reports them.
    * Its **pose** relative to the stereo pair (`VisionCore.Camera.Pose`)
      as a `tf2_msgs/TFMessage` transform from the stereo left optical
      frame to the camera's `frame_id` (`transform_message/3`).

  `set_camera_info`'s service name is `<root>/set_camera_info`. The
  `<root>` is the camera's name, `<topic_prefix>/<name>` with a
  `:topic_prefix` (`topic_root/2`).
  """
  require Logger

  alias Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo
  alias Ros2Zenoh.GeometryMsgs.Msg.{Quaternion, Transform, TransformStamped, Vector3}
  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage}
  alias Ros2Zenoh.StdMsgs.Msg.{Float64, Header}
  alias Ros2Zenoh.Tf2Msgs.Msg.TFMessage
  alias VisionCore.Camera.{Frame, Pose}
  alias VisionCore.Ros2.{CameraCalibration, Stamp}
  alias VisionCore.Ros2.ZenohExporter.Stereo

  @default_raw_image_max_hz 10
  @default_camera_info_interval_frames 30

  @typedoc """
  One camera's: its name, frame id, topics, service, calibration and
  pose, the frames seen, the next image's slot and the frame size its
  calibration was last logged as not fitting.
  """
  @type t :: %{
          name: atom(),
          frame_id: String.t(),
          image_topic: String.t(),
          camera_info_topic: String.t(),
          video_topic: String.t(),
          service_name: String.t(),
          calibration: CameraCalibration.t() | nil,
          pose: Pose.t() | nil,
          raw_image_max_hz: number(),
          camera_info_interval_frames: pos_integer(),
          frame_counter: non_neg_integer(),
          next_image_ms: number() | nil,
          misfit_size: {pos_integer(), pos_integer()} | nil
        }

  @doc """
  The camera of `settings` (`VisionCore.Camera.Unit.settings/1`) with
  its calibration and pose read, and `options`: `:topic_prefix` (none),
  `:raw_image_max_hz` (10) and `:camera_info_interval_frames` (30). A
  calibration or pose that cannot be read is left out, with a warning.
  """
  @spec new(VisionCore.Camera.Unit.settings(), keyword()) :: t()
  def new(settings, options) do
    options =
      Keyword.validate!(options, [
        :topic_prefix,
        raw_image_max_hz: @default_raw_image_max_hz,
        camera_info_interval_frames: @default_camera_info_interval_frames
      ])

    topic_root = topic_root(options[:topic_prefix], settings.name)

    %{
      name: settings.name,
      frame_id: settings.frame_id,
      image_topic: "#{topic_root}/image_raw/compressed",
      camera_info_topic: "#{topic_root}/camera_info",
      video_topic: "#{topic_root}/image_raw/h264",
      service_name: service_name(options[:topic_prefix], settings.name),
      calibration: calibration(settings.calibration_path, settings.name),
      pose: load_pose(settings.pose_path, settings.name),
      raw_image_max_hz: options[:raw_image_max_hz],
      camera_info_interval_frames: options[:camera_info_interval_frames],
      frame_counter: 0,
      next_image_ms: nil,
      misfit_size: nil
    }
  end

  @doc "The `set_camera_info` service of the camera `name` under `topic_prefix`, if any."
  @spec service_name(String.t() | nil, atom()) :: String.t()
  def service_name(topic_prefix, name), do: "#{topic_root(topic_prefix, name)}/set_camera_info"

  @doc "The namespace of the camera `name`'s topics: its name, under `topic_prefix` when given."
  @spec topic_root(String.t() | nil, atom()) :: String.t()
  def topic_root(nil, name), do: Atom.to_string(name)
  def topic_root(topic_prefix, name), do: "#{topic_prefix}/#{name}"

  @doc """
  The exposure and gain in `live_metadata`, what the camera under
  `topic_root` applied (`c:VisionCore.Camera.live/1`), as
  `std_msgs/Float64` on `<topic_root>/exposure_us` and
  `<topic_root>/analogue_gain`; none for a figure it did not report.
  """
  @spec live_messages(String.t(), map() | nil) :: [Stereo.message()]
  def live_messages(topic_root, live_metadata) do
    for {key, topic} <- [exposure_time_us: "exposure_us", analogue_gain: "analogue_gain"],
        is_map(live_metadata),
        is_number(live_metadata[key]),
        do: {"#{topic_root}/#{topic}", Float64, %Float64{data: live_metadata[key] * 1.0}}
  end

  @doc "`camera` with its calibration read again from `calibration_path`."
  @spec reload(t(), Path.t() | nil) :: t()
  def reload(camera, calibration_path),
    do: %{
      camera
      | calibration: calibration(calibration_path, camera.name),
        misfit_size: nil
    }

  @doc "`camera` with its pose read again from `pose_path`, none without a path."
  @spec reload_pose(t(), Path.t() | nil) :: t()
  def reload_pose(camera, pose_path), do: %{camera | pose: load_pose(pose_path, camera.name)}

  @doc """
  The messages of the camera's `frame` at `now_ms`, and the camera after
  it: the frame as an image when its slot is open, encoded by `encode`,
  then the camera info every Nth frame. A frame that does not encode
  takes its slot all the same.
  """
  @spec frame_messages(Frame.t(), t(), number(), (Frame.t() -> Stereo.encoded())) ::
          {[Stereo.message()], t()}
  def frame_messages(%Frame{} = frame, camera, now_ms, encode) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(frame.capture_ns),
      frame_id: frame.frame_id || camera.frame_id
    }

    {image, camera} = image(frame, camera, header, now_ms, encode)

    {camera_info, camera} =
      if rem(camera.frame_counter, camera.camera_info_interval_frames) == 0 do
        {message, camera} = camera_info(camera, header, frame)
        {[{camera.camera_info_topic, CameraInfo, message}], camera}
      else
        {[], camera}
      end

    {image ++ camera_info, %{camera | frame_counter: camera.frame_counter + 1}}
  end

  defp image(frame, camera, header, now_ms, encode) do
    case Stereo.image_slot(camera.next_image_ms, frame, now_ms, camera.raw_image_max_hz) do
      {:publish, next_ms} ->
        camera = %{camera | next_image_ms: next_ms}

        case encode.(frame) do
          {:ok, jpeg} ->
            message = %CompressedImage{header: header, format: "jpeg", data: jpeg}
            {[{camera.image_topic, CompressedImage, message}], camera}

          {:error, _reason} ->
            {[], camera}
        end

      :skip ->
        {[], camera}
    end
  end

  @doc """
  The message of `frame`, a frame of the camera's H.264 output: its
  stream frame as `foxglove_msgs/CompressedVideo`, stamped with its
  capture time, in the frame id it carries or the camera's.
  """
  @spec video_message(Frame.t(), t()) :: Stereo.message()
  def video_message(%Frame{h264: h264} = frame, camera) when is_binary(h264) do
    video = %CompressedVideo{
      timestamp: Stamp.stamp_from_monotonic(frame.capture_ns),
      frame_id: frame.frame_id || camera.frame_id,
      data: h264,
      format: "h264"
    }

    {camera.video_topic, CompressedVideo, video}
  end

  defp camera_info(%{calibration: nil} = camera, header, frame),
    do: {empty_camera_info(header, frame), camera}

  defp camera_info(%{calibration: calibration} = camera, header, %Frame{} = frame) do
    if CameraCalibration.proportional?(calibration, frame.width, frame.height),
      do: {scaled_camera_info(calibration, header, frame), camera},
      else: {empty_camera_info(header, frame), note_misfit(camera, frame)}
  end

  defp empty_camera_info(header, %Frame{width: width, height: height}),
    do: %CameraInfo{header: header, width: width, height: height}

  defp scaled_camera_info(calibration, header, %Frame{width: width, height: height}) do
    calibration
    |> CameraCalibration.resample_to(width, height)
    |> CameraCalibration.camera_info(header, width, height)
  end

  defp note_misfit(%{misfit_size: {width, height}} = camera, %Frame{width: width, height: height}),
       do: camera

  defp note_misfit(camera, %Frame{width: width, height: height}) do
    %{calibration: calibration} = camera

    Logger.warning(
      "camera #{camera.name}: its #{calibration.width}x#{calibration.height} calibration does " <>
        "not fit its #{width}x#{height} frames, of another aspect ratio, so its camera info is " <>
        "empty: calibrate the camera at that size"
    )

    %{camera | misfit_size: {width, height}}
  end

  @doc """
  The static transforms of the `cameras` that have a pose, from
  `parent_frame_id`, the stereo left optical frame, to each camera's
  frame id, stamped `stamp`; `nil` when none has a pose.

  A pose maps a point of the left frame into the camera's,
  `p_camera = R * p_left + t`; a transform places the child frame in its
  parent, `p_left = Rᵀ * p_camera - Rᵀ * t`, so it carries `Rᵀ` and
  `-Rᵀ * t`.
  """
  @spec transform_message([t()], String.t(), term()) :: struct() | nil
  def transform_message(cameras, parent_frame_id, stamp) do
    case for(%{pose: %Pose{} = pose} = camera <- cameras, do: {camera, pose}) do
      [] ->
        nil

      posed ->
        %TFMessage{
          transforms:
            Enum.map(posed, fn {camera, pose} ->
              %TransformStamped{
                header: %Header{stamp: stamp, frame_id: parent_frame_id},
                child_frame_id: camera.frame_id,
                transform: inverse_transform(pose)
              }
            end)
        }
    end
  end

  defp inverse_transform(%Pose{rotation: rotation, translation: [tx, ty, tz]}) do
    [r00, r01, r02, r10, r11, r12, r20, r21, r22] = rotation
    transposed = [r00, r10, r20, r01, r11, r21, r02, r12, r22]

    %Transform{
      translation: %Vector3{
        x: -(r00 * tx + r10 * ty + r20 * tz),
        y: -(r01 * tx + r11 * ty + r21 * tz),
        z: -(r02 * tx + r12 * ty + r22 * tz)
      },
      rotation: quaternion(transposed)
    }
  end

  # Shepperd's method: the branch on the largest diagonal term keeps the square root away from zero.
  defp quaternion([m00, m01, m02, m10, m11, m12, m20, m21, m22]) do
    trace = m00 + m11 + m22

    {x, y, z, w} =
      cond do
        trace > 0 ->
          s = :math.sqrt(trace + 1.0) * 2
          {(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4}

        m00 > m11 and m00 > m22 ->
          s = :math.sqrt(1.0 + m00 - m11 - m22) * 2
          {s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s}

        m11 > m22 ->
          s = :math.sqrt(1.0 + m11 - m00 - m22) * 2
          {(m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s}

        true ->
          s = :math.sqrt(1.0 + m22 - m00 - m11) * 2
          {(m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s}
      end

    norm = :math.sqrt(x * x + y * y + z * z + w * w)
    %Quaternion{x: x / norm, y: y / norm, z: z / norm, w: w / norm}
  end

  @doc """
  The calibration at `path` of the camera `name`; `nil` without a path or
  when it cannot be read, with a warning that its camera info is empty.
  """
  @spec calibration(Path.t() | nil, atom()) :: CameraCalibration.t() | nil
  def calibration(nil, name) do
    Logger.warning(
      "#{__MODULE__}: no calibration for camera #{name}; publishing empty CameraInfo"
    )

    nil
  end

  def calibration(path, name) do
    case CameraCalibration.load(path) do
      {:ok, calibration} ->
        calibration

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}: cannot read calibration #{inspect(path)} for camera #{name} " <>
            "(#{inspect(reason)}); publishing empty CameraInfo"
        )

        nil
    end
  end

  defp load_pose(nil, name) do
    Logger.info("#{__MODULE__}: camera #{name} has no pose; no transform from the stereo pair")
    nil
  end

  defp load_pose(path, name) do
    case Pose.load(path) do
      {:ok, pose} ->
        pose

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__}: cannot read pose #{inspect(path)} for camera #{name} " <>
            "(#{inspect(reason)}); no transform from the stereo pair"
        )

        nil
    end
  end
end
