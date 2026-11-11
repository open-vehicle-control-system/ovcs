defmodule Ovcs1.VisionComposerTest do
  use ExUnit.Case, async: true

  test "OVCS1's vision unit targets the VENTUNO Q" do
    assert Ovcs1.vision_target() == :arduino_ventuno_q
    assert Ovcs1.vision() == Ovcs1.Vision.Composer
    assert %VisionCore.Config{} = Ovcs1.Vision.Composer.config(:host)
    assert %VisionCore.Config{} = Ovcs1.Vision.Composer.config(:target)
  end

  test "the stereo component matches the rig" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(components, :stereo)

    assert stereo[:driver] == VisionCore.Camera.V4L2
    assert {stereo[:width], stereo[:height]} == {728, 544}
    assert {stereo[:match_width], stereo[:match_height]} == {728, 544}
    assert stereo[:defn_options][:byte_storage] == false
    assert stereo[:left][:left_csiphy] == 0
    assert stereo[:left][:right_csiphy] == 1

    disparity = stereo[:stages][VisionCore.Stereo.Stage.Disparity]
    assert disparity[:num_disparities] == 128
    assert disparity[:search] == "coarse_to_fine"
    assert disparity[:coarse_paths] == 3
    refute disparity[:paths]
  end

  test "detection runs on the NPU" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)
    detector = Keyword.fetch!(components, :qnn_detector)

    assert String.ends_with?(detector[:dlc_path], "priv/models/yolox_w8a8.dlc")
    assert "priv/models/yolox_w8a8.dlc" in Ovcs1.Vision.Composer.required_files()
  end

  test "the HQ camera runs on Camera 2 at 35 fps in half-resolution colour, for driving" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)
    camera = Keyword.fetch!(components, :camera)

    assert camera[:name] == :hq
    assert camera[:driver] == VisionCore.Camera.V4L2Single
    assert camera[:csiphy] == 2
    assert camera[:fps] == 35
    assert camera[:output] == :half
    assert camera[:max_exposure_us] == 25_000
  end

  test "the calibration gives the rig's 20 cm baseline" do
    dir = Application.app_dir(:ovcs1, "priv/calibration")

    for side <- ["left", "right"],
        do:
          assert(
            {:ok, _} =
              VisionCore.Ros2.CameraCalibration.load(Path.join(dir, "stereo_#{side}.yaml"))
          )

    right = VisionCore.Ros2.CameraCalibration.load!(Path.join(dir, "stereo_right.yaml"))
    [fx, _, _, tx | _] = right.projection_matrix
    # A calibration measures the mounting's spacing, a few millimetres off it.
    assert_in_delta -tx / fx, 0.2, 5.0e-3
  end
end
