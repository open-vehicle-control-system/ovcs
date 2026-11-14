defmodule VisionCore.Ros2.ZenohExporter.CameraTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo
  alias Ros2Zenoh.GeometryMsgs.Msg.TransformStamped
  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage}
  alias Ros2Zenoh.StdMsgs.Msg.Float64
  alias Ros2Zenoh.Tf2Msgs.Msg.TFMessage
  alias VisionCore.Camera.{Frame, Pose}
  alias VisionCore.Ros2.ZenohExporter.Camera

  @moduletag :capture_log
  @calibration Path.expand("../../../support/calibration", __DIR__)

  defp settings(overrides) do
    Map.merge(
      %{
        name: :hq,
        server: :hq_server,
        frame_id: "hq_optical",
        calibration_path: Path.join(@calibration, "distorted_left.yaml"),
        calibration_store_path: nil,
        pose_path: nil
      },
      overrides
    )
  end

  defp camera(overrides \\ %{}, options \\ []),
    do:
      Camera.new(
        settings(overrides),
        Keyword.merge(
          [raw_image_max_hz: 10, camera_info_interval_frames: 2],
          options
        )
      )

  defp rgb_frame(width, height, capture_ns \\ 0),
    do: %Frame{
      label: "hq",
      frame_id: "hq_optical",
      width: width,
      height: height,
      capture_ns: capture_ns,
      rgb: :binary.copy(<<0>>, width * height * 3)
    }

  defp encode(%Frame{width: width}), do: {:ok, "jpeg #{width}"}

  defp assert_values(values, expected) do
    assert length(values) == length(expected)
    for {value, want} <- Enum.zip(values, expected), do: assert_in_delta(value, want, 1.0e-9)
  end

  defp write_pose(tmp_dir, rotation, translation) do
    path = Path.join(tmp_dir, "hq_pose.yaml")

    File.write!(
      path,
      "rotation: #{inspect(rotation)}\ntranslation: #{inspect(translation)}\n"
    )

    path
  end

  test "its topics and service are under its name" do
    camera = camera()

    assert camera.image_topic == "hq/image_raw/compressed"
    assert camera.camera_info_topic == "hq/camera_info"
    assert camera.service_name == "hq/set_camera_info"
    assert camera.video_topic == "hq/image_raw/h264"
  end

  test "its topics and service are under <prefix>/<name>/ with a :topic_prefix" do
    camera = camera(%{}, topic_prefix: "front")

    assert camera.image_topic == "front/hq/image_raw/compressed"
    assert camera.camera_info_topic == "front/hq/camera_info"
    assert camera.service_name == "front/hq/set_camera_info"
    assert camera.video_topic == "front/hq/image_raw/h264"
    assert Camera.service_name("front", :hq) == "front/hq/set_camera_info"
    assert Camera.service_name(nil, :hq) == "hq/set_camera_info"
    assert Camera.topic_root("front", :hq) == "front/hq"
    assert Camera.topic_root(nil, :hq) == "hq"
  end

  describe "live_messages/2" do
    test "are the exposure and gain the camera applied, under its topic root" do
      assert [
               {"hq/exposure_us", Float64, %Float64{data: 8000.0}},
               {"hq/analogue_gain", Float64, %Float64{data: 2.5}}
             ] =
               Camera.live_messages("hq", %{
                 exposure_time_us: 8_000,
                 analogue_gain: 2.5,
                 received_ms: 0
               })
    end

    test "leave out a figure the camera did not report, and are none before a report" do
      assert [{"hq/analogue_gain", Float64, _gain}] =
               Camera.live_messages("hq", %{exposure_time_us: nil, analogue_gain: 1.0})

      assert Camera.live_messages("hq", nil) == []
    end
  end

  describe "video_message/2" do
    test "is a frame of the H.264 stream, stamped, in the frame id it carries or the camera's" do
      frame = %Frame{
        label: "hq",
        frame_id: "hq_optical",
        width: 2028,
        height: 1520,
        capture_ns: 0,
        h264: <<0, 0, 0, 1, 0x65>>,
        keyframe?: true
      }

      assert {"hq/image_raw/h264", CompressedVideo, video} = Camera.video_message(frame, camera())

      assert %CompressedVideo{
               timestamp: %Time{},
               frame_id: "hq_optical",
               data: <<0, 0, 0, 1, 0x65>>,
               format: "h264"
             } = video

      assert {_topic, CompressedVideo, %CompressedVideo{frame_id: "camera_optical"}} =
               Camera.video_message(
                 %{frame | frame_id: nil},
                 camera(%{frame_id: "camera_optical"})
               )
    end
  end

  describe "frame_messages/4" do
    test "publishes the image, encoded, and the camera info every Nth frame, in the frame's frame id" do
      camera = camera()

      {messages, camera} = Camera.frame_messages(rgb_frame(96, 72), camera, 0, &encode/1)

      assert [
               {"hq/image_raw/compressed", CompressedImage, image},
               {"hq/camera_info", CameraInfo, camera_info}
             ] = messages

      assert image.data == "jpeg 96"
      assert image.format == "jpeg"
      assert image.header.frame_id == "hq_optical"
      assert camera_info.header == image.header

      {messages, _camera} = Camera.frame_messages(rgb_frame(96, 72), camera, 1_000, &encode/1)
      assert [{"hq/image_raw/compressed", CompressedImage, _image}] = messages
    end

    test "publishes at most raw_image_max_hz images a second" do
      camera = camera(%{}, camera_info_interval_frames: 100)

      {[_image | _camera_info], camera} =
        Camera.frame_messages(rgb_frame(96, 72), camera, 0, &encode/1)

      assert {[], camera} = Camera.frame_messages(rgb_frame(96, 72), camera, 50, &encode/1)

      assert {[_image], _camera} =
               Camera.frame_messages(rgb_frame(96, 72), camera, 100, &encode/1)
    end

    test "its camera info is K and D, R identity and P = K padded, at the calibration's size" do
      {[_image, {_topic, CameraInfo, camera_info}], _camera} =
        Camera.frame_messages(rgb_frame(96, 72), camera(), 0, &encode/1)

      assert {camera_info.width, camera_info.height} == {96, 72}
      assert camera_info.distortion_model == "plumb_bob"
      assert camera_info.d == [-0.21, 0.05, 0.0012, -0.0008, -0.004]
      assert camera_info.k == [81.3, 0.0, 47.2, 0.0, 80.9, 35.6, 0.0, 0.0, 1.0]
      assert camera_info.r == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
      assert camera_info.p == [81.3, 0.0, 47.2, 0.0, 0.0, 80.9, 35.6, 0.0, 0.0, 0.0, 1.0, 0.0]
    end

    test "resamples a calibration of another size to the frame's, pixel centres on pixel centres" do
      {[_image, {_topic, CameraInfo, camera_info}], _camera} =
        Camera.frame_messages(rgb_frame(48, 36), camera(), 0, &encode/1)

      assert {camera_info.width, camera_info.height} == {48, 36}
      assert_values(camera_info.k, [40.65, 0.0, 23.35, 0.0, 40.45, 17.55, 0.0, 0.0, 1.0])

      assert_values(
        camera_info.p,
        [40.65, 0.0, 23.35, 0.0, 0.0, 40.45, 17.55, 0.0, 0.0, 0.0, 1.0, 0.0]
      )
    end

    test "an equidistant calibration keeps its model and four coefficients, scaled to a half frame" do
      equidistant = camera(%{calibration_path: Path.join(@calibration, "equidistant_hq.yaml")})

      {[_image, {_topic, CameraInfo, camera_info}], _camera} =
        Camera.frame_messages(rgb_frame(1014, 760), equidistant, 0, &encode/1)

      assert camera_info.distortion_model == "equidistant"
      assert camera_info.d == [0.05, -0.02, 0.006, -0.002]
      assert_values(camera_info.k, [405.0, 0.0, 507.0, 0.0, 404.5, 380.0, 0.0, 0.0, 1.0])
      assert camera_info.r == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]

      assert_values(
        camera_info.p,
        [405.0, 0.0, 507.0, 0.0, 0.0, 404.5, 380.0, 0.0, 0.0, 0.0, 1.0, 0.0]
      )
    end

    test "a calibration of another aspect ratio than the frame's gives an empty camera info, saying so once" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {[_image, {_topic, CameraInfo, camera_info}], camera} =
            Camera.frame_messages(rgb_frame(96, 40), camera(), 0, &encode/1)

          assert {camera_info.width, camera_info.height} == {96, 40}
          assert camera_info.k == %CameraInfo{}.k

          {_messages, camera} = Camera.frame_messages(rgb_frame(96, 40), camera, 1_000, &encode/1)

          {_messages, _camera} =
            Camera.frame_messages(rgb_frame(96, 40), camera, 2_000, &encode/1)
        end)

      assert [_once] = Regex.scan(~r/96x72 calibration .* 96x40/, log)
    end

    test "without a calibration, an empty camera info of the frame's size" do
      {[_image, {_topic, CameraInfo, camera_info}], _camera} =
        Camera.frame_messages(rgb_frame(48, 36), camera(%{calibration_path: nil}), 0, &encode/1)

      assert {camera_info.width, camera_info.height} == {48, 36}
      assert camera_info.k == %CameraInfo{}.k
    end

    test "a frame that does not encode takes its slot, and its camera info still goes out" do
      {messages, _camera} =
        Camera.frame_messages(rgb_frame(96, 72), camera(), 0, fn _frame -> {:error, :codec} end)

      assert [{"hq/camera_info", CameraInfo, _camera_info}] = messages
    end
  end

  @tag :tmp_dir
  test "reload/2 reads the calibration again, from the path given", %{tmp_dir: tmp_dir} do
    stored = Path.join(tmp_dir, "hq.yaml")
    File.cp!(Path.join(@calibration, "identity_left.yaml"), stored)

    camera = Camera.reload(camera(), stored)

    {[_image, {_topic, CameraInfo, camera_info}], _camera} =
      Camera.frame_messages(rgb_frame(192, 108), camera, 0, &encode/1)

    assert camera_info.k == [200.0, 0.0, 96.0, 0.0, 200.0, 54.0, 0.0, 0.0, 1.0]
    assert camera_info.d == [0.0, 0.0, 0.0, 0.0, 0.0]
  end

  @tag :tmp_dir
  test "reload_pose/2 reads the pose again, from the path given", %{tmp_dir: tmp_dir} do
    pose_path = write_pose(tmp_dir, [1, 0, 0, 0, 1, 0, 0, 0, 1], [-0.2, 0.0, 0.0])

    assert Camera.reload_pose(camera(), pose_path).pose.translation == [-0.2, 0.0, 0.0]
    assert Camera.reload_pose(camera(%{pose_path: pose_path}), nil).pose == nil
  end

  describe "the static transform" do
    @describetag :tmp_dir

    test "is the camera's pose inverted: the camera's frame placed in the stereo left's", %{
      tmp_dir: tmp_dir
    } do
      # The camera 0.1 m to the right of the left camera, turned 90° about its optical axis.
      pose_path = write_pose(tmp_dir, [0, 1, 0, -1, 0, 0, 0, 0, 1], [0.0, 0.1, 0.0])
      camera = camera(%{pose_path: pose_path})

      assert %Pose{} = camera.pose

      assert %TFMessage{transforms: [%TransformStamped{} = transform]} =
               Camera.transform_message([camera], "stereo_left_optical", 7)

      assert transform.header.frame_id == "stereo_left_optical"
      assert transform.header.stamp == 7
      assert transform.child_frame_id == "hq_optical"

      # p_left = Rᵀ (p_camera - t): the camera's origin sits at -Rᵀ t = (0.1, 0, 0).
      assert_in_delta transform.transform.translation.x, 0.1, 1.0e-12
      assert_in_delta transform.transform.translation.y, 0.0, 1.0e-12
      assert_in_delta transform.transform.translation.z, 0.0, 1.0e-12

      # Rᵀ turns +90° about z.
      rotation = transform.transform.rotation
      half = :math.sqrt(0.5)
      assert_in_delta rotation.x, 0.0, 1.0e-12
      assert_in_delta rotation.y, 0.0, 1.0e-12
      assert_in_delta rotation.z, half, 1.0e-12
      assert_in_delta rotation.w, half, 1.0e-12
    end

    test "a half turn about x makes a unit quaternion", %{tmp_dir: tmp_dir} do
      pose_path = write_pose(tmp_dir, [1, 0, 0, 0, -1, 0, 0, 0, -1], [0.0, 0.0, 0.0])

      %TFMessage{transforms: [transform]} =
        Camera.transform_message([camera(%{pose_path: pose_path})], "stereo_left_optical", 0)

      rotation = transform.transform.rotation
      assert_in_delta abs(rotation.x), 1.0, 1.0e-12
      assert_in_delta rotation.y, 0.0, 1.0e-12
      assert_in_delta rotation.z, 0.0, 1.0e-12
      assert_in_delta rotation.w, 0.0, 1.0e-12
    end

    test "leaves out a camera without a pose, or whose pose cannot be read, and is nil without any",
         %{tmp_dir: tmp_dir} do
      missing = camera(%{pose_path: Path.join(tmp_dir, "none.yaml")})

      assert missing.pose == nil
      assert Camera.transform_message([camera(), missing], "stereo_left_optical", 0) == nil
    end
  end
end
