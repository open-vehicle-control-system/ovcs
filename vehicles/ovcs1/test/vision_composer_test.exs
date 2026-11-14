defmodule Ovcs1.VisionComposerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VisionCore.CameraDepth
  alias VisionCore.CameraDepth.Reprojection
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

    assert stereo[:driver] == VisionCore.Camera.V4L2Pair
    assert {stereo[:width], stereo[:height]} == {728, 544}
    assert {stereo[:match_width], stereo[:match_height]} == {728, 544}
    assert stereo[:defn_options][:byte_storage] == false
    assert stereo[:left][:csiphy] == 0
    assert stereo[:right][:csiphy] == 1
    assert stereo[:black_level] == 60

    assert {:ok, _cameras} =
             VisionCore.Stereo.Supervisor.camera_options(Ovcs1.Vision.Composer.config(:target))

    disparity = stereo[:stages][VisionCore.Stereo.Stage.Disparity]
    assert disparity[:num_disparities] == 128
    assert disparity[:search] == "coarse_to_fine"
    assert disparity[:coarse_paths] == 3
    refute disparity[:paths]
  end

  test "the pipelines' settings are values their vision parameters take" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    assert %{detect_every_n: 1} =
             VisionCore.Detection.Pipeline.settings(Keyword.fetch!(components, :qnn_detector))

    assert %{segment_every_n: 1, band_top: 1.0} =
             VisionCore.Segmentation.Pipeline.init(Keyword.fetch!(components, :qnn_segmenter))

    assert %{pair_tolerance_ms: 5} =
             VisionCore.Settings.init!(
               VisionCore.Stereo.Pairer.setting_specs(),
               Keyword.fetch!(components, :stereo)
             )
  end

  test "detection runs on the NPU on the center camera, not on the stereo pair" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    assert [detector] = Keyword.get_values(components, :qnn_detector)
    assert detector[:name] == :objects
    assert detector[:source] == {:camera, :center, :half}
    assert detector[:score_threshold] == 0.4
    assert String.ends_with?(detector[:dlc_path], "priv/models/yolox_w8a8.dlc")
    assert "priv/models/yolox_w8a8.dlc" in Ovcs1.Vision.Composer.required_files()
  end

  test "scene segmentation runs on the NPU on the center camera" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    assert [segmenter] = Keyword.get_values(components, :qnn_segmenter)
    assert segmenter[:name] == :scene
    assert segmenter[:source] == {:camera, :center, :half}
    assert segmenter[:segment_every_n] == 1
    assert String.ends_with?(segmenter[:dlc_path], "priv/models/ffnet_122ns_lowres.dlc")
    assert "priv/models/ffnet_122ns_lowres.dlc" in Ovcs1.Vision.Composer.required_files()
  end

  test "the center camera runs on Camera 2 at 30 fps in full-resolution colour, sent as H.264, and at half for the models and as a JPEG" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)
    camera = Keyword.fetch!(components, :camera)

    assert camera[:name] == :center
    assert camera[:driver] == VisionCore.Camera.V4L2Single
    assert camera[:csiphy] == 2
    assert camera[:fps] == 30
    refute camera[:output]

    assert camera[:outputs] == [
             full: [resolution: {2028, 1520}, processor: :cpu, send: false],
             half: [resolution: {1014, 760}, from: :full],
             half_jpeg: [from: :half, format: :jpeg, quality: 80],
             full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
           ]

    config = Ovcs1.Vision.Composer.config(:target)

    assert {:ok, [full, half, half_jpeg, full_h264]} =
             VisionCore.Camera.Unit.camera_outputs(config, :center)

    assert {full.name, full.index, full.width, full.height, full.send} ==
             {:full, 0, 2028, 1520, false}

    assert {half.index, half.width, half.height, half.from} ==
             {1, 1014, 760, :full}

    assert {full_h264.index, full_h264.width, full_h264.height, full_h264.format} ==
             {2, 2028, 1520, :h264}

    assert {half_jpeg.index, half_jpeg.width, half_jpeg.height, half_jpeg.format} ==
             {3, 1014, 760, :jpeg}

    # The full image is made only for the video and the half image: it never crosses the Port.
    assert [%{outputs: [^half, ^half_jpeg]}] = VisionCore.Camera.Unit.settings(config)
    server = VisionCore.Camera.V4L2Single.name_for("center")
    assert VisionCore.Camera.Unit.output_key(config, :center, :full) == nil

    assert VisionCore.Camera.Unit.output_key(config, :center, nil) ==
             {:camera_frame, server, :half}

    assert VisionCore.Camera.Unit.video_key(config, :center, :full_h264) ==
             {:camera_frame, server, :full_h264}

    assert camera[:max_exposure_us] == 25_000
    assert camera[:frame_id] == "center_optical"
  end

  test "the dashboard and ROS 2 show the center camera's video, ROS 2 its half image as a JPEG" do
    config = Ovcs1.Vision.Composer.config(:target)
    exporter = Keyword.fetch!(config.exporters, VisionCore.Ros2.Exporter)

    assert config.preview[:videos] == [center: :full_h264]
    assert config.preview[:outputs] == [center: :half_jpeg]
    assert config.preview[:max_hz] == 30
    assert VisionCore.Camera.Unit.video_output?(config, :center, :full_h264)
    assert VisionCore.Camera.Unit.output_key(config, :center, config.preview[:outputs][:center])
    assert exporter[:cameras][:outputs] == [center: :half_jpeg]
    assert exporter[:cameras][:videos] == [center: :full_h264]
  end

  test "the center camera's calibration and pose sit beside the stereo pair's" do
    config = Ovcs1.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(config.components, :stereo)

    assert [center] = VisionCore.Camera.Unit.settings(config)
    assert center.name == :center
    assert center.frame_id == "center_optical"
    assert String.ends_with?(center.calibration_path, "priv/calibration/center.yaml")
    assert String.ends_with?(center.pose_path, "priv/calibration/center_pose.yaml")
    assert center.calibration_store_path == "/data/vision/calibration/camera_center.yaml"
    assert Path.dirname(center.calibration_store_path) == stereo[:calibration_store_dir]
    assert "priv/calibration/center.yaml" in Ovcs1.Vision.Composer.required_files()
    refute "priv/calibration/center_pose.yaml" in Ovcs1.Vision.Composer.required_files()
  end

  test "the center camera's nominal calibration is for its full output" do
    path = Application.app_dir(:ovcs1, "priv/calibration/center.yaml")

    calibration = CameraCalibration.load!(path)

    assert {calibration.width, calibration.height} == {2028, 1520}
    assert calibration.camera_matrix == [1161.3, 0.0, 1013.5, 0.0, 1161.3, 759.5, 0.0, 0.0, 1.0]
    assert calibration.distortion_model == "plumb_bob"
    assert Enum.all?(calibration.distortion_coefficients, &(&1 == 0.0))
    assert Reprojection.check(calibration) == :ok
  end

  test "the center camera's pipelines run without distances until the camera's pose is measured" do
    config = Ovcs1.Vision.Composer.config(:target)
    assert [%{pose_path: pose_path}] = VisionCore.Camera.Unit.settings(config)
    refute File.exists?(pose_path)

    wording = %{pose: "its detections have no distance", unreadable: "they have none"}

    {depth, log} =
      with_log(fn ->
        CameraDepth.new(:center, config, "detection pipeline objects", wording, pair_wait_ms: 500)
      end)

    assert depth.calibration
    refute depth.pose
    refute CameraDepth.projectable?(depth)
    assert log =~ "camera center has no pose"
    refute log =~ "unreadable"
  end

  test "every vision unit takes its options as the vision core starts it" do
    %VisionCore.Config{components: components} = Ovcs1.Vision.Composer.config(:target)

    for {component, opts} <- components,
        %{start: {unit, :start_link, [unit_opts]}} <-
          VisionCore.Components.start(component, opts) do
      assert {:ok, _children} = unit.init(unit_opts)
    end
  end

  test "the ROS 2 exporter publishes the center camera, its detections and its scene" do
    config = Ovcs1.Vision.Composer.config(:target)
    options = Keyword.fetch!(config.exporters, VisionCore.Ros2.Exporter)

    assert options[:detections][:pipelines] == [:objects]
    assert options[:cameras][:names] == [:center]
    assert options[:segmentation][:pipelines] == [:scene]

    assert VisionCore.Exporter.output_key({:camera_frame, :center, :half_jpeg}, config) ==
             {:camera_frame, VisionCore.Camera.V4L2Single.name_for("center"), :half_jpeg}

    assert VisionCore.Exporter.output_key({:camera_video, :center, :full_h264}, config) ==
             {:camera_frame, VisionCore.Camera.V4L2Single.name_for("center"), :full_h264}
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
