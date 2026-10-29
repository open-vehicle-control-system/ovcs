defmodule VisionCore.Ros2.Publishers.Stereo do
  @moduledoc """
  Publishes a stereo unit on ROS 2: each side's raw image and
  intrinsics as the camera drivers deliver them, and the disparity,
  depth and point cloud of each `VisionCore.Stereo.Pair` the pipeline
  finishes.

    * **Raw images** on `<topic_prefix>/<side>/image_raw/compressed`,
      and **calibration** on `<topic_prefix>/<side>/camera_info` every
      Nth frame, so late subscribers see it without latched QoS.
    * **Stereo outputs**, all stamped with the left frame's capture time
      so consumers can pair them with the raw streams:

        * `stereo_msgs/DisparityImage` on `:disparity_topic` — the
          canonical topic, and the only one carrying the geometry
          (`f`, `T`, `valid_window`).
        * a 16UC1 `sensor_msgs/Image` of **millimetres** on
          `:depth_topic`, the ROS depth-image convention.
        * `sensor_msgs/CameraInfo` on `:depth_camera_info_topic` when
          set — the left camera's intrinsics at the matching size, from
          the pair's geometry, since the depth image is in the rectified
          left frame. Without a camera_info sibling a
          viewer cannot project the depth image. Its `K` is `P`'s 3x3
          block and `D` is zero: the image is rectified, so a consumer
          that reaches for `K` instead of `P` still unprojects
          correctly.
        * `sensor_msgs/PointCloud2` on `:cloud_topic` when set and the
          pair has points.
        * the disparity pixels again as a bare 32FC1
          `sensor_msgs/Image` on `:disparity_image_topic` — only when
          set, since viewers match on a topic's type and will not
          reach inside the `DisparityImage` container. Opt-in for
          bandwidth reasons; see `:publish_disparity_image` in
          `VisionCore.Stereo.Supervisor`.

  ## Required options

    * `:cameras` — `[{driver_module, "left"}, {driver_module,
      "right"}]`.
    * `:topic_prefix` — root for per-side image topics
      (`<prefix>/<side>/image_raw/compressed` and
      `<prefix>/<side>/camera_info`).
    * `:disparity_topic`, `:depth_topic` — full Zenoh topics for the
      stereo outputs.
    * `:left`, `:right` — per-side keyword lists. Each requires
      `:frame_id` (used in every outgoing header for that side)
      and optionally `:calibration_path` (a
      `camera_calibration_parsers` YAML — see
      `VisionCore.Ros2.CameraCalibration`).
    * `:width`, `:height` — fall-back dimensions used in
      CameraInfo when the calibration YAML doesn't supply them.

  ## Optional options

    * `:pipeline` (`VisionCore.Stereo.Pipeline`) — the pipeline server.
    * `:camera_info_interval_frames` — republish CameraInfo every
      Nth frame. Default 30.
    * `:publish_raw_images` (`true`) — republish each camera frame on
      `<prefix>/<side>/image_raw/compressed`. Off when the frames
      already come from that topic, as `VisionCore.Ros2.Camera`'s do
      against a simulator: republishing them would feed them back in.
    * `:raw_image_max_hz` (10) — the most raw images a second, per side,
      for grey frames, which are JPEG-encoded here; JPEG frames are
      republished as they arrive.
    * `:depth_camera_info_topic`, `:cloud_topic`,
      `:disparity_image_topic`, `:rectified_image_topic`,
      `:right_rectified_image_topic` — each output is published only
      when its topic is given; `nil` (the default) skips it. The
      rectified topics carry the rectified left and right images as
      JPEG, row-aligned, with the depth image's header.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.{CameraCalibration, Stamp}
  alias VisionCore.Stereo.{Pair, Pipeline, StageTimer}

  alias Ros2Zenoh.SensorMsgs.Msg.{
    CameraInfo,
    CompressedImage,
    Image,
    PointCloud2,
    RegionOfInterest
  }

  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage

  @default_camera_info_interval_frames 30
  @default_raw_image_max_hz 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    cameras = Keyword.fetch!(opts, :cameras)
    topic_prefix = Keyword.fetch!(opts, :topic_prefix)
    disparity_topic = Keyword.fetch!(opts, :disparity_topic)
    disparity_image_topic = Keyword.get(opts, :disparity_image_topic)
    depth_topic = Keyword.fetch!(opts, :depth_topic)
    depth_camera_info_topic = Keyword.get(opts, :depth_camera_info_topic)
    cloud_topic = Keyword.get(opts, :cloud_topic)
    rectified_image_topic = Keyword.get(opts, :rectified_image_topic)
    right_rectified_image_topic = Keyword.get(opts, :right_rectified_image_topic)
    publish_raw_images = Keyword.get(opts, :publish_raw_images, true)
    left_opts = Keyword.fetch!(opts, :left)
    right_opts = Keyword.fetch!(opts, :right)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    pipeline = Keyword.get(opts, :pipeline, Pipeline)

    camera_info_interval_frames =
      Keyword.get(opts, :camera_info_interval_frames, @default_camera_info_interval_frames)

    {left_driver, "left"} = locate_side(cameras, "left")
    {right_driver, "right"} = locate_side(cameras, "right")

    Pipeline.register_listener(pipeline, self())
    left_driver.register_listener(left_driver.name_for("left"), self())
    right_driver.register_listener(right_driver.name_for("right"), self())

    Logger.info(
      "#{__MODULE__} publishing #{inspect(left_driver)}[left], " <>
        "#{inspect(right_driver)}[right], #{disparity_topic} and #{depth_topic}"
    )

    {:ok,
     %{
       sides: %{
         "left" =>
           build_side_state("left", topic_prefix, left_opts, width, height, publish_raw_images),
         "right" =>
           build_side_state("right", topic_prefix, right_opts, width, height, publish_raw_images)
       },
       camera_info_interval_frames: camera_info_interval_frames,
       raw_image_max_hz: Keyword.get(opts, :raw_image_max_hz, @default_raw_image_max_hz),
       disparity_topic: disparity_topic,
       disparity_image_topic: disparity_image_topic,
       depth_topic: depth_topic,
       depth_camera_info_topic: depth_camera_info_topic,
       cloud_topic: cloud_topic,
       rectified_image_topic: rectified_image_topic,
       right_rectified_image_topic: right_rectified_image_topic,
       # The depth + disparity outputs are anchored to the left
       # camera's frame, per ROS convention.
       stereo_frame_id: Keyword.fetch!(left_opts, :frame_id),
       telemetry: StageTimer.new(window: 30, label: "publisher"),
       last_pair_at_ns: nil
     }}
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{} = frame}, state),
    do: {:noreply, publish_image(state, frame)}

  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    now_ns = System.monotonic_time(:nanosecond)
    {publish_ns, _} = measure_ns(fn -> publish_stereo(state, pair) end)

    pair_interval_ns =
      case state.last_pair_at_ns do
        nil -> 0
        last_pair_at_ns -> now_ns - last_pair_at_ns
      end

    telemetry =
      state.telemetry
      |> StageTimer.record(:pub_stereo, publish_ns)
      |> StageTimer.record(:wall, pair_interval_ns)
      |> StageTimer.tick()

    {:noreply, %{state | telemetry: telemetry, last_pair_at_ns: now_ns}}
  end

  defp measure_ns(fun) do
    start_ns = System.monotonic_time(:nanosecond)
    return_value = fun.()
    {System.monotonic_time(:nanosecond) - start_ns, return_value}
  end

  defp publish_image(state, %Frame{label: label} = frame) do
    case Map.fetch(state.sides, label) do
      {:ok, side} ->
        header = %Header{
          stamp: Stamp.stamp_from_monotonic(frame.capture_ns),
          frame_id: side.frame_id
        }

        slot =
          if is_binary(side.image_topic),
            do:
              image_slot(
                side.next_image_ms,
                frame,
                System.monotonic_time(:millisecond),
                state.raw_image_max_hz
              ),
            else: :skip

        {publish_ns, side} =
          measure_ns(fn ->
            case slot do
              {:publish, next_ms} ->
                publish_compressed_image(side.image_topic, header, frame)
                %{side | next_image_ms: next_ms}

              :skip ->
                side
            end
          end)

        if rem(side.frame_counter, state.camera_info_interval_frames) == 0 do
          publish_camera_info(side.camera_info_topic, header, side.camera_info, frame)
        end

        stage = String.to_atom("pub_#{label}")

        state
        |> update_in([:telemetry], &StageTimer.record(&1, stage, publish_ns))
        |> update_in([:telemetry], &StageTimer.bump(&1, String.to_atom("frames_#{label}")))
        |> put_in([:sides, label], %{side | frame_counter: side.frame_counter + 1})

      :error ->
        Logger.warning(
          "#{__MODULE__}: dropping frame from unexpected camera label #{inspect(label)}"
        )

        state
    end
  end

  @doc """
  Whether to publish `frame` as a raw image at `now_ms`. A JPEG frame is
  always published. A grey frame, which has to be encoded, is published
  once the side's next slot, `next_ms`, has opened: slots are
  `1000 / max_hz` ms apart, so frames on a coarser grid still average
  `max_hz`. Returns the next slot when the frame is published.
  """
  def image_slot(next_ms, %Frame{jpeg: jpeg}, _now_ms, _max_hz) when is_binary(jpeg),
    do: {:publish, next_ms}

  def image_slot(nil, %Frame{}, now_ms, max_hz), do: {:publish, now_ms + 1_000 / max_hz}

  def image_slot(next_ms, %Frame{}, now_ms, max_hz) when now_ms >= next_ms,
    do: {:publish, max(next_ms + 1_000 / max_hz, now_ms)}

  def image_slot(_next_ms, %Frame{}, _now_ms, _max_hz), do: :skip

  defp publish_compressed_image(topic, header, %Frame{} = frame) do
    with {:ok, jpeg} <- Frame.to_jpeg(frame) do
      message = %CompressedImage{header: header, format: "jpeg", data: jpeg}
      VisionCore.Ros2.ZenohClient.publish(topic, CompressedImage, message)
    end
  end

  @doc "A rectified image as a JPEG."
  @spec encode_image(Nx.Tensor.t() | nil) :: {:ok, binary()} | {:error, term()}
  def encode_image(%Nx.Tensor{} = image), do: VisionCore.Jpeg.encode_tensor(image)
  def encode_image(_image), do: {:error, :no_image}

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

  defp publish_camera_info(
         topic,
         header,
         %CameraInfo{} = camera_info,
         %Frame{width: width, height: height}
       ) do
    # `camera_info` is already scaled to the configured capture resolution.
    message =
      if camera_info.width == width and camera_info.height == height do
        %CameraInfo{camera_info | header: header}
      else
        %CameraInfo{camera_info | header: header, width: width, height: height}
      end

    VisionCore.Ros2.ZenohClient.publish(topic, CameraInfo, message)
  end

  defp publish_stereo(state, %Pair{} = pair) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(Pair.capture_ns(pair)),
      frame_id: state.stereo_frame_id
    }

    {width, height} = Pair.size(pair)
    {valid_x, valid_y, valid_width, valid_height} = Pair.valid_window(pair)
    {min_disparity, max_disparity} = Pair.disparity_bounds(pair)

    disparity_image = %Image{
      header: header,
      height: height,
      width: width,
      # DisparityImage.image is a float disparity image per the spec.
      encoding: "32FC1",
      is_bigendian: 0,
      step: width * 4,
      data: pair.disparity_bytes
    }

    disparity_message = %DisparityImage{
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
      delta_d: Pair.delta_d(pair)
    }

    depth_message = %Image{
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

    VisionCore.Ros2.ZenohClient.publish(state.disparity_topic, DisparityImage, disparity_message)
    VisionCore.Ros2.ZenohClient.publish(state.depth_topic, Image, depth_message)

    if state.cloud_topic && pair.cloud && pair.cloud_points > 0 do
      VisionCore.Ros2.ZenohClient.publish(state.cloud_topic, PointCloud2, %PointCloud2{
        header: header,
        height: 1,
        width: pair.cloud_points,
        fields: PointCloud2.xyz_fields(),
        is_bigendian: 0,
        point_step: PointCloud2.point_step(),
        row_step: pair.cloud_points * PointCloud2.point_step(),
        data: pair.cloud,
        # Unmatched pixels are dropped, not encoded as sentinels, so
        # every point here is a real measurement.
        is_dense: 1
      })
    end

    for {topic, image} <- [
          {state.rectified_image_topic, pair.left},
          {state.right_rectified_image_topic, pair.right}
        ],
        is_binary(topic),
        {:ok, jpeg} <- [encode_image(image)] do
      VisionCore.Ros2.ZenohClient.publish(topic, CompressedImage, %CompressedImage{
        header: header,
        format: "jpeg",
        data: jpeg
      })
    end

    # Consumers look for camera_info next to the depth image topic.
    if state.depth_camera_info_topic do
      VisionCore.Ros2.ZenohClient.publish(
        state.depth_camera_info_topic,
        CameraInfo,
        depth_camera_info(pair.geometry.left_calibration, header)
      )
    end

    # `disparity_message.image` as a bare Image, for viewers that match on topic type.
    if state.disparity_image_topic do
      VisionCore.Ros2.ZenohClient.publish(state.disparity_image_topic, Image, disparity_image)
    end
  end

  @doc false
  def build_side_state(
        side,
        topic_prefix,
        side_opts,
        fallback_width,
        fallback_height,
        publish_raw_images
      ) do
    %{
      frame_id: Keyword.fetch!(side_opts, :frame_id),
      image_topic: publish_raw_images && "#{topic_prefix}/#{side}/image_raw/compressed",
      camera_info_topic: "#{topic_prefix}/#{side}/camera_info",
      camera_info:
        load_camera_info(
          Keyword.get(side_opts, :calibration_path),
          fallback_width,
          fallback_height,
          side
        ),
      frame_counter: 0,
      next_image_ms: nil
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

  defp locate_side(cameras, side) do
    case Enum.find(cameras, fn {_driver, label} -> label == side end) do
      {driver, label} -> {driver, label}
      nil -> raise "#{__MODULE__}: no camera labelled #{inspect(side)} in :cameras opt"
    end
  end
end
