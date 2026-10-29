defmodule VisionCore.Ros2.Publishers.StereoTest do
  use ExUnit.Case, async: false

  alias VisionCore.Ros2.Publishers.Stereo

  @side_opts [frame_id: "left_camera"]

  test "republishes the raw images by default" do
    side = Stereo.build_side_state("left", "stereo", @side_opts, 4, 4, true)
    assert side.image_topic == "stereo/left/image_raw/compressed"
  end

  test "keeps the camera info but not the raw images when told not to republish them" do
    side = Stereo.build_side_state("left", "stereo", @side_opts, 4, 4, false)
    refute side.image_topic
    assert side.camera_info_topic == "stereo/left/camera_info"
  end

  describe "raw image rate" do
    alias VisionCore.Camera.Frame

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

  describe "rectified images" do
    @describetag :jpeg

    test "a tensor from the Nx stages is encoded" do
      start_supervised!(VisionCore.Jpeg)
      image = Nx.iota({12, 16}, type: :u8)

      assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Stereo.encode_image(image)
    end
  end
end
