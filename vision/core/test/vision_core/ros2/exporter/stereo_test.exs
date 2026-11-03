defmodule VisionCore.Ros2.Exporter.StereoTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage, Image, PointCloud2}
  alias Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Exporter.Stereo
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log

  @side_options [frame_id: "left_camera"]
  @calibration Path.expand("../../../support/calibration", __DIR__)

  defp stereo(options \\ []),
    do: Stereo.new([left: @side_options, right: [frame_id: "right_camera"]] ++ options)

  defp pair do
    frame = %Frame{label: "left", width: 8, height: 4, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      left: Nx.broadcast(Nx.u8(0), {4, 8}),
      right: Nx.broadcast(Nx.u8(1), {4, 8}),
      geometry: %{
        focal_length_px: 600.0,
        baseline_m: 0.08,
        left_calibration: CameraCalibration.load!(Path.join(@calibration, "stereo_left.yaml"))
      },
      disparity_range: %{min_disparity: 0, num_disparities: 2, block_size: 1},
      disparity_scale: 16,
      disparity_bytes: :binary.copy(<<0::32>>, 32),
      depth: :binary.copy(<<0::16>>, 32),
      cloud: :binary.copy(<<0::32>>, 3 * 2),
      cloud_points: 2,
      cloud_size: {1, 2}
    }
  end

  # Stands in for the JPEG codec: names the image it was given.
  defp encode(%Nx.Tensor{} = image), do: {:ok, "jpeg of #{Nx.to_number(image[0][0])}"}
  defp encode(%Frame{label: label}), do: {:ok, "jpeg of #{label}"}

  defp topics(messages), do: Enum.map(messages, fn {topic, _module, _message} -> topic end)

  describe "a stereo pair" do
    test "makes the disparity, the depth in millimetres and the organized point cloud" do
      assert [
               {"stereo/disparity", DisparityImage, disparity},
               {"stereo/depth/image_rect", Image, depth},
               {"stereo/points", PointCloud2, cloud},
               {"stereo/depth/camera_info", CameraInfo, _camera_info}
             ] = Stereo.pair_messages(pair(), stereo(), &encode/1)

      assert %{width: 8, height: 4, encoding: "32FC1", step: 32} = disparity.image
      assert {disparity.f, disparity.t} == {600.0, 0.08}

      assert {disparity.min_disparity, disparity.max_disparity, disparity.delta_d} ==
               {0.0, 1.0, 0.0625}

      assert %{x_offset: 2, y_offset: 0, width: 5, height: 4} = disparity.valid_window
      assert %{width: 8, height: 4, encoding: "16UC1", step: 16} = depth
      assert %{height: 1, width: 2, is_dense: 0} = cloud
      assert cloud.row_step == 2 * cloud.point_step
      assert disparity.header.frame_id == "left_camera"
    end

    test "gives the depth the left camera's rectified intrinsics: K from P, no distortion" do
      messages = Stereo.pair_messages(pair(), stereo(), &encode/1)

      assert {_topic, CameraInfo, camera_info} =
               List.keyfind(messages, "stereo/depth/camera_info", 0)

      assert camera_info.k == [50.0, 0.0, 32.0, 0.0, 50.0, 24.0, 0.0, 0.0, 1.0]
      assert camera_info.d == [0.0, 0.0, 0.0, 0.0, 0.0]
    end

    test "makes no point cloud for a pair without points" do
      messages = Stereo.pair_messages(%Pair{pair() | cloud_points: 0}, stereo(), &encode/1)

      refute "stereo/points" in topics(messages)
    end

    test "adds the rectified images, encoded, and the bare disparity image when asked" do
      messages =
        Stereo.pair_messages(
          pair(),
          stereo(publish_rectified_image: true, publish_disparity_image: true),
          &encode/1
        )

      assert topics(messages) == [
               "stereo/disparity",
               "stereo/depth/image_rect",
               "stereo/points",
               "stereo/left/image_rect/compressed",
               "stereo/right/image_rect/compressed",
               "stereo/depth/camera_info",
               "stereo/disparity/image"
             ]

      assert [{_topic, CompressedImage, left}, {_, CompressedImage, right}] =
               Enum.filter(messages, &match?({_topic, CompressedImage, _message}, &1))

      assert {left.data, right.data} == {"jpeg of 0", "jpeg of 1"}
      assert {_topic, Image, %{encoding: "32FC1"}} = List.last(messages)
    end

    test "leaves out a rectified image the pair does not have, or that does not encode" do
      stereo = stereo(publish_rectified_image: true)

      without_right = Stereo.pair_messages(%Pair{pair() | right: nil}, stereo, &encode/1)
      refute "stereo/right/image_rect/compressed" in topics(without_right)
      assert "stereo/left/image_rect/compressed" in topics(without_right)

      unencodable = Stereo.pair_messages(pair(), stereo, fn _image -> {:error, :busy} end)
      refute Enum.any?(unencodable, &match?({_topic, CompressedImage, _message}, &1))
    end

    test "names its topics under the prefix" do
      messages = Stereo.pair_messages(pair(), stereo(topic_prefix: "front"), &encode/1)

      assert Enum.all?(topics(messages), &String.starts_with?(&1, "front/"))
    end
  end

  describe "a camera's frame" do
    defp grey(label), do: %Frame{label: label, width: 1, height: 1, capture_ns: 0, grey: <<0>>}

    test "makes the raw image, then the side's camera info every Nth frame" do
      stereo = stereo(camera_info_interval_frames: 2)

      {first, side} =
        Stereo.frame_messages(grey("left"), stereo.sides["left"], stereo, 0, &encode/1)

      assert [
               {"stereo/left/image_raw/compressed", CompressedImage, image},
               {"stereo/left/camera_info", CameraInfo, camera_info}
             ] = first

      assert image.data == "jpeg of left"
      assert image.header.frame_id == "left_camera"
      assert {camera_info.width, camera_info.height} == {1, 1}

      {second, side} = Stereo.frame_messages(grey("left"), side, stereo, 200, &encode/1)
      assert topics(second) == ["stereo/left/image_raw/compressed"]

      {third, _side} = Stereo.frame_messages(grey("left"), side, stereo, 400, &encode/1)
      assert "stereo/left/camera_info" in topics(third)
    end

    test "makes no raw image when told not to republish them, and still the camera info" do
      stereo = stereo(publish_raw_images: false)

      {messages, _side} =
        Stereo.frame_messages(grey("right"), stereo.sides["right"], stereo, 0, &encode/1)

      assert topics(messages) == ["stereo/right/camera_info"]
    end

    test "leaves out a raw image that does not encode" do
      stereo = stereo()

      {messages, _side} =
        Stereo.frame_messages(grey("left"), stereo.sides["left"], stereo, 0, fn _frame ->
          {:error, :busy}
        end)

      assert topics(messages) == ["stereo/left/camera_info"]
    end
  end

  describe "a side" do
    test "republishes the raw images by default" do
      side = Stereo.side("left", "stereo", @side_options, 4, 4, true)
      assert side.image_topic == "stereo/left/image_raw/compressed"
    end

    test "keeps the camera info but not the raw images when told not to republish them" do
      side = Stereo.side("left", "stereo", @side_options, 4, 4, false)
      refute side.image_topic
      assert side.camera_info_topic == "stereo/left/camera_info"
    end

    test "is named after the prefix without a frame id" do
      assert Stereo.side("right", "front", [], 4, 4, true).frame_id == "front_right"
    end

    @tag :tmp_dir
    test "reloads its camera info from the calibration a commit rewrote", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "stereo_left.yaml")
      File.cp!(Path.join(@calibration, "stereo_left.yaml"), path)

      side =
        Stereo.side("left", "stereo", [calibration_path: path] ++ @side_options, 64, 48, true)

      File.cp!(Path.join(@calibration, "distorted_left.yaml"), path)
      reloaded = Stereo.reload_side(side, nil)

      refute reloaded.camera_info.k == side.camera_info.k
      assert reloaded.camera_info.d != side.camera_info.d
    end

    test "reloads its camera info from a new calibration path" do
      side =
        Stereo.side(
          "left",
          "stereo",
          [calibration_path: Path.join(@calibration, "stereo_left.yaml")] ++ @side_options,
          64,
          48,
          true
        )

      reloaded = Stereo.reload_side(side, Path.join(@calibration, "distorted_left.yaml"))

      refute reloaded.camera_info.d == side.camera_info.d
      assert reloaded.calibration_path == Path.join(@calibration, "distorted_left.yaml")
    end
  end

  test "reloads both sides, each from the path given for it" do
    stereo =
      Stereo.new(
        left: [calibration_path: Path.join(@calibration, "stereo_left.yaml")],
        right: [calibration_path: Path.join(@calibration, "stereo_right.yaml")],
        width: 64,
        height: 48
      )

    reloaded =
      Stereo.reload(stereo, left_calibration_path: Path.join(@calibration, "distorted_left.yaml"))

    refute reloaded.sides["left"].camera_info.d == stereo.sides["left"].camera_info.d
    assert reloaded.sides["right"].camera_info == stereo.sides["right"].camera_info
  end

  describe "raw image rate" do
    defp published(frame, max_hz) do
      {count, _next} =
        Enum.reduce(0..29, {0, nil}, fn index, {count, next_ms} ->
          case Stereo.image_slot(next_ms, frame, index * 33, max_hz) do
            {:publish, next_ms} -> {count + 1, next_ms}
            :skip -> {count, next_ms}
          end
        end)

      count
    end

    test "grey frames are encoded and published at most max_hz" do
      grey = %Frame{label: "left", width: 1, height: 1, capture_ns: 0, grey: <<0>>}
      assert published(grey, 10) in 9..10
    end

    test "JPEG frames are published as they arrive" do
      jpeg = %Frame{label: "left", width: 1, height: 1, capture_ns: 0, jpeg: <<0xFF, 0xD8>>}
      assert published(jpeg, 10) == 30
    end
  end
end
