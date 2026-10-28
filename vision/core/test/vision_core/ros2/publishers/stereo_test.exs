defmodule VisionCore.Ros2.Publishers.StereoTest do
  use ExUnit.Case, async: true

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
end
