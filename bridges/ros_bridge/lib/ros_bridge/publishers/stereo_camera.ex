defmodule RosBridge.Publishers.StereoCamera do
  @moduledoc """
  Owns everything the bridge publishes for a stereo pair: each
  side's raw image + intrinsics, plus the disparity + depth maps
  derived from them. Sole consumer of the two camera drivers'
  `:camera_frame` casts.

  ## Responsibilities

    1. **Re-publish each captured frame** on
       `<topic_prefix>/<side>/image_raw/compressed` with a
       wall-clock-projected header stamp.
    2. **Republish calibration** (loaded from the per-side YAML)
       on `<topic_prefix>/<side>/camera_info` every Nth frame so
       late subscribers see it without us needing real
       latched-QoS support.
    3. **Pair frames by timestamp.** Both sides arrive
       independently; we keep the freshest of each and emit a
       pair once their `Frame.capture_ns` differ by less than
       `:pair_tolerance_ms`.
    4. **Drive the stereo backend** (`RosBridge.StereoCamera.OpenCV`)
       with one pair at a time. Backpressure: while a previous
       pair is still being processed (`awaiting_result == true`)
       new pairs are silently dropped — we'd rather skip than
       build a backlog.
    5. **Publish disparity + depth** when the backend returns a
       `%RosBridge.StereoCamera.Result{}`: a `stereo_msgs/DisparityImage`
       on `:disparity_topic` and a 32FC1 `sensor_msgs/Image` on
       `:depth_topic`. Both reuse the left frame's stamp so
       downstream consumers can pair them with the raw streams via
       `Header.stamp`.

  ## Required opts

    * `:cameras` — `[{driver_module, "left"}, {driver_module,
      "right"}]`.
    * `:topic_prefix` — root for per-side image topics
      (`<prefix>/<side>/image_raw/compressed` and
      `<prefix>/<side>/camera_info`).
    * `:disparity_topic`, `:depth_topic` — full Zenoh topics for
      the stereo outputs.
    * `:left`, `:right` — per-side keyword lists. Each requires
      `:frame_id` (used in every outgoing header for that side)
      and optionally `:calibration_path` (a
      `camera_calibration_parsers` YAML — see
      `RosBridge.Camera.Calibration`).
    * `:width`, `:height` — fall-back dimensions used in
      CameraInfo when the calibration YAML doesn't supply them.

  ## Optional opts

    * `:pair_tolerance_ms` — max wall-clock gap between paired
      stamps. Default 33 ms (one frame period at 30 fps); wide
      enough for unsynchronized USB cameras with a stable phase
      offset.
    * `:camera_info_interval_frames` — republish CameraInfo every
      Nth frame. Default 30 (≈ once per second at 30 fps).
  """
  use GenServer
  require Logger

  alias RosBridge.Camera.Calibration
  alias RosBridge.Camera.Frame
  alias RosBridge.StereoCamera.OpenCV
  alias RosBridge.StereoCamera.Result
  alias RosBridge.StereoCamera.Telemetry
  alias RosBridge.Timing
  alias Ros2.SensorMsgs.Msg.CameraInfo
  alias Ros2.SensorMsgs.Msg.CompressedImage
  alias Ros2.SensorMsgs.Msg.Image
  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.StereoMsgs.Msg.DisparityImage

  @default_pair_tolerance_ms 33
  @default_camera_info_interval_frames 30

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    cameras = Keyword.fetch!(opts, :cameras)
    topic_prefix = Keyword.fetch!(opts, :topic_prefix)
    disparity_topic = Keyword.fetch!(opts, :disparity_topic)
    depth_topic = Keyword.fetch!(opts, :depth_topic)
    left_opts = Keyword.fetch!(opts, :left)
    right_opts = Keyword.fetch!(opts, :right)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    pair_tolerance_ms = Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms)

    camera_info_interval_frames =
      Keyword.get(opts, :camera_info_interval_frames, @default_camera_info_interval_frames)

    {left_driver, "left"} = locate_side(cameras, "left")
    {right_driver, "right"} = locate_side(cameras, "right")

    OpenCV.register_listener(OpenCV, self())
    left_driver.register_listener(left_driver.name_for("left"), self())
    right_driver.register_listener(right_driver.name_for("right"), self())

    Logger.info(
      "#{__MODULE__} pairing #{inspect(left_driver)}[left] ↔ " <>
        "#{inspect(right_driver)}[right] → " <>
        "#{disparity_topic} + #{depth_topic} (tolerance #{pair_tolerance_ms} ms)"
    )

    {:ok,
     %{
       sides: %{
         "left" => build_side_state("left", topic_prefix, left_opts, width, height),
         "right" => build_side_state("right", topic_prefix, right_opts, width, height)
       },
       camera_info_interval_frames: camera_info_interval_frames,
       disparity_topic: disparity_topic,
       depth_topic: depth_topic,
       # The depth + disparity outputs are anchored to the left
       # camera's frame, per ROS convention.
       stereo_frame_id: Keyword.fetch!(left_opts, :frame_id),
       pair_tolerance_ns: pair_tolerance_ms * 1_000_000,
       latest_left: nil,
       latest_right: nil,
       awaiting_result: false,
       telemetry: Telemetry.new(window: 30, label: "publisher"),
       last_result_at: nil,
       submit_at: nil
     }}
  end

  @impl true
  def handle_cast({:camera_frame, %Frame{} = frame}, state) do
    state =
      state
      |> publish_image(frame)
      |> stash_for_pairing(frame)
      |> maybe_submit_pair()

    {:noreply, state}
  end

  def handle_cast({:stereo_result, %Result{} = result}, state) do
    now = System.monotonic_time(:nanosecond)

    {publish_ns, _} = time(fn -> publish_stereo(state, result) end)

    backend_round_trip_ns =
      case state.submit_at do
        nil -> 0
        submit_at -> now - submit_at
      end

    wall_ns =
      case state.last_result_at do
        nil -> 0
        last -> now - last
      end

    telemetry =
      state.telemetry
      |> Telemetry.record(:pub_stereo, publish_ns)
      |> Telemetry.record(:backend_rt, backend_round_trip_ns)
      |> Telemetry.record(:wall, wall_ns)
      |> Telemetry.tick()

    state = %{
      state
      | awaiting_result: false,
        telemetry: telemetry,
        last_result_at: now,
        submit_at: nil
    }

    # Frames may have arrived while the backend was busy; if a
    # fresh pair is ready now, submit immediately rather than
    # waiting for the next `:camera_frame` cast. This closes the
    # one-frame-period gap between result-arrival and the next
    # pair submit.
    {:noreply, maybe_submit_pair(state)}
  end

  defp time(fun) do
    start = System.monotonic_time(:nanosecond)
    value = fun.()
    {System.monotonic_time(:nanosecond) - start, value}
  end

  # ── per-side image + camera_info ─────────────────────────────

  defp publish_image(state, %Frame{label: label} = frame) do
    case Map.fetch(state.sides, label) do
      {:ok, side} ->
        header = %Header{
          stamp: Timing.time_message_for(frame.capture_ns),
          frame_id: side.frame_id
        }

        {publish_ns, _} =
          time(fn -> publish_compressed_image(side.topic_image, header, frame) end)

        if rem(side.frame_counter, state.camera_info_interval_frames) == 0 do
          publish_camera_info(side.topic_info, header, side.camera_info, frame)
        end

        stage = String.to_atom("pub_#{label}")

        state
        |> update_in([:telemetry], &Telemetry.record(&1, stage, publish_ns))
        |> update_in([:telemetry], &Telemetry.bump(&1, String.to_atom("frames_#{label}")))
        |> put_in([:sides, label, :frame_counter], side.frame_counter + 1)

      :error ->
        Logger.warning(
          "#{__MODULE__}: dropping frame from unexpected camera label #{inspect(label)}"
        )

        state
    end
  end

  defp publish_compressed_image(topic, header, %Frame{jpeg: jpeg}) do
    message = %CompressedImage{header: header, format: "jpeg", data: jpeg}
    RosBridge.ZenohClient.publish(topic, CompressedImage, message)
  end

  defp publish_camera_info(topic, header, %CameraInfo{} = base, %Frame{width: w, height: h}) do
    message = %CameraInfo{
      base
      | header: header,
        width: max(base.width, w),
        height: max(base.height, h)
    }

    RosBridge.ZenohClient.publish(topic, CameraInfo, message)
  end

  # ── pairing ──────────────────────────────────────────────────

  defp stash_for_pairing(state, %Frame{label: "left"} = frame),
    do: %{state | latest_left: frame}

  defp stash_for_pairing(state, %Frame{label: "right"} = frame),
    do: %{state | latest_right: frame}

  defp stash_for_pairing(state, _frame), do: state

  defp maybe_submit_pair(state) do
    case ready_pair(state) do
      :not_ready ->
        state

      {:out_of_tolerance, delta_ns} ->
        update_in(state.telemetry, fn telemetry ->
          telemetry
          |> Telemetry.record(:pair_delta, delta_ns)
          |> Telemetry.bump(:drop_tolerance)
        end)

      {:ok, _left, _right, delta_ns} when state.awaiting_result ->
        update_in(state.telemetry, fn telemetry ->
          telemetry
          |> Telemetry.record(:pair_delta, delta_ns)
          |> Telemetry.bump(:drop_busy)
        end)

      {:ok, left, right, delta_ns} ->
        OpenCV.submit_pair(OpenCV, left, right)

        %{
          state
          | latest_left: nil,
            latest_right: nil,
            awaiting_result: true,
            submit_at: System.monotonic_time(:nanosecond),
            telemetry: Telemetry.record(state.telemetry, :pair_delta, delta_ns)
        }
    end
  end

  defp ready_pair(%{latest_left: nil}), do: :not_ready
  defp ready_pair(%{latest_right: nil}), do: :not_ready

  defp ready_pair(%{latest_left: left, latest_right: right, pair_tolerance_ns: tolerance}) do
    delta_ns = abs(left.capture_ns - right.capture_ns)

    if delta_ns <= tolerance do
      {:ok, left, right, delta_ns}
    else
      {:out_of_tolerance, delta_ns}
    end
  end

  # ── disparity + depth publish ────────────────────────────────

  defp publish_stereo(state, %Result{} = result) do
    header = %Header{
      stamp: Timing.time_message_for(result.capture_ns),
      frame_id: state.stereo_frame_id
    }

    disparity_image = %Image{
      header: header,
      height: result.height,
      width: result.width,
      encoding: "16UC1",
      is_bigendian: 0,
      step: result.disparity_step,
      data: result.disparity
    }

    disparity_message = %DisparityImage{
      header: header,
      image: disparity_image,
      f: result.focal_length / 1.0,
      t: result.baseline / 1.0,
      valid_window: %RegionOfInterest{
        x_offset: result.valid_x,
        y_offset: result.valid_y,
        width: result.valid_w,
        height: result.valid_h,
        do_rectify: false
      },
      min_disparity: result.min_disparity,
      max_disparity: result.max_disparity,
      delta_d: result.delta_d
    }

    depth_message = %Image{
      header: header,
      height: result.height,
      width: result.width,
      encoding: "32FC1",
      is_bigendian: 0,
      step: result.depth_step,
      data: result.depth
    }

    RosBridge.ZenohClient.publish(state.disparity_topic, DisparityImage, disparity_message)
    RosBridge.ZenohClient.publish(state.depth_topic, Image, depth_message)
  end

  # ── init helpers ─────────────────────────────────────────────

  defp build_side_state(side, topic_prefix, side_opts, fallback_width, fallback_height) do
    %{
      frame_id: Keyword.fetch!(side_opts, :frame_id),
      topic_image: "#{topic_prefix}/#{side}/image_raw/compressed",
      topic_info: "#{topic_prefix}/#{side}/camera_info",
      camera_info: load_camera_info(Keyword.get(side_opts, :calibration_path), fallback_width, fallback_height, side),
      frame_counter: 0
    }
  end

  defp load_camera_info(nil, width, height, side) do
    Logger.warning(
      "#{__MODULE__}: no calibration path for #{side}; publishing empty CameraInfo"
    )

    %CameraInfo{width: width, height: height}
  end

  defp load_camera_info(path, width, height, side) do
    case Calibration.load(path) do
      {:ok, calibration} ->
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
