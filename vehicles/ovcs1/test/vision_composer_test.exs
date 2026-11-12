defmodule Ovcs1.VisionComposerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VisionCore.Detection.{CameraSource, Reprojection}
  alias VisionCore.Ros2.CameraCalibration

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

  test "detection runs on the NPU on the HQ camera, not on the stereo pair" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    assert [detector] = Keyword.get_values(components, :qnn_detector)
    assert detector[:name] == :objects
    assert detector[:source] == {:camera, :hq}
    assert detector[:score_threshold] == 0.4
    assert String.ends_with?(detector[:dlc_path], "priv/models/yolox_w8a8.dlc")
    assert "priv/models/yolox_w8a8.dlc" in Ovcs1.Vision.Composer.required_files()
  end

  test "road segmentation runs on the NPU on the HQ camera" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    assert [segmenter] = Keyword.get_values(components, :qnn_segmenter)
    assert segmenter[:name] == :road
    assert segmenter[:source] == {:camera, :hq}
    assert String.ends_with?(segmenter[:dlc_path], "priv/models/ffnet_122ns_lowres.dlc")
    assert "priv/models/ffnet_122ns_lowres.dlc" in Ovcs1.Vision.Composer.required_files()
  end

  test "the HQ camera runs on Camera 2 at 35 fps in full-resolution colour, for driving" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)
    camera = Keyword.fetch!(components, :camera)

    assert camera[:name] == :hq
    assert camera[:driver] == VisionCore.Camera.V4L2Single
    assert camera[:csiphy] == 2
    assert camera[:fps] == 35
    assert camera[:output] == :full
    assert camera[:max_exposure_us] == 25_000
    assert camera[:frame_id] == "hq_optical"
  end

  test "the HQ camera's calibration and pose sit beside the stereo pair's" do
    config = Ovcs1.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(config.components, :stereo)

    assert [hq] = VisionCore.Camera.Unit.settings(config)
    assert hq.name == :hq
    assert hq.frame_id == "hq_optical"
    assert String.ends_with?(hq.calibration_path, "priv/calibration/hq.yaml")
    assert String.ends_with?(hq.pose_path, "priv/calibration/hq_pose.yaml")
    assert hq.calibration_store_path == "/data/vision/calibration/camera_hq.yaml"
    assert Path.dirname(hq.calibration_store_path) == stereo[:calibration_store_dir]
    assert "priv/calibration/hq.yaml" in Ovcs1.Vision.Composer.required_files()
    refute "priv/calibration/hq_pose.yaml" in Ovcs1.Vision.Composer.required_files()
  end

  test "the HQ camera's nominal calibration is for its full output" do
    path = Application.app_dir(:ovcs1, "priv/calibration/hq.yaml")

    calibration = CameraCalibration.load!(path)

    assert {calibration.width, calibration.height} == {2028, 1520}
    assert calibration.camera_matrix == [1161.3, 0.0, 1013.5, 0.0, 1161.3, 759.5, 0.0, 0.0, 1.0]
    assert calibration.distortion_model == "plumb_bob"
    assert Enum.all?(calibration.distortion_coefficients, &(&1 == 0.0))
    assert Reprojection.check(calibration) == :ok
  end

  test "the HQ pipelines run without distances until the camera's pose is measured" do
    config = Ovcs1.Vision.Composer.config(:target)
    assert [%{pose_path: pose_path}] = VisionCore.Camera.Unit.settings(config)
    refute File.exists?(pose_path)

    {source, log} = with_log(fn -> CameraSource.new(:hq, config, :objects, 500) end)

    assert source.calibration
    refute source.pose
    refute CameraSource.placeable?(source)
    assert log =~ "camera hq has no pose"
    assert log =~ "hq_pose.yaml unreadable (:enoent)"
  end

  test "every vision unit takes its options as the vision core starts it" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    for {component, opts} <- components,
        %{start: {unit, :start_link, [unit_opts]}} <-
          VisionCore.Components.start(component, opts) do
      assert {:ok, _children} = unit.init(unit_opts)
    end
  end

  test "the ROS 2 exporter publishes the HQ camera, its detections and its road" do
    config = Ovcs1.Vision.Composer.config(:target)
    options = Keyword.fetch!(config.exporters, VisionCore.Ros2.Exporter)

    assert options[:detections][:pipelines] == [:objects]
    assert options[:cameras][:names] == [:hq]
    assert options[:segmentation][:pipelines] == [:road]
  end

  test "the ROS 2 exporter's outputs are all produced by the configuration" do
    config = Ovcs1.Vision.Composer.config(:target)
    options = Keyword.fetch!(config.exporters, VisionCore.Ros2.Exporter) ++ [config: config]

    assert VisionCore.Ros2.Exporter.check(options) == :ok
    assert {:ok, specs} = VisionCore.Exporter.output_specs(VisionCore.Ros2.Exporter, options)

    for {output, _max_hz} <- specs,
        do: assert(VisionCore.Exporter.output_key(output, config), inspect(output))
  end

  test "the calibration gives the rig's 20 cm baseline" do
    dir = Application.app_dir(:ovcs1, "priv/calibration")

    for side <- ["left", "right"],
        do: assert({:ok, _} = CameraCalibration.load(Path.join(dir, "stereo_#{side}.yaml")))

    right = CameraCalibration.load!(Path.join(dir, "stereo_right.yaml"))
    [fx, _, _, tx | _] = right.projection_matrix
    # A calibration measures the mounting's spacing, a few millimetres off it.
    assert_in_delta -tx / fx, 0.2, 5.0e-3
  end
end
