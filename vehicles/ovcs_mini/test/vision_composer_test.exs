defmodule OvcsMini.VisionComposerTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{LibCamera, LibCameraStream}
  alias VisionCore.Ros2.{BagExporter, ZenohExporter}
  alias VisionCore.Ros2.BagExporter.Preset

  defp camera(%VisionCore.Config{components: components}, name) do
    Enum.find_value(components, fn
      {:camera, opts} -> if opts[:name] == name, do: opts
      _component -> nil
    end)
  end

  test "the stereo unit matches at most 20 pairs a second, a value its vision parameter takes" do
    %VisionCore.Config{components: components} = OvcsMini.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(components, :stereo)

    assert %{max_hz: 20.0, pair_tolerance_ms: 5} =
             VisionCore.Settings.init!(VisionCore.Stereo.Pairer.setting_specs(), stereo)

    assert {:ok, _cameras} =
             VisionCore.Stereo.Supervisor.camera_options(OvcsMini.Vision.Composer.config(:target))
  end

  test "the bag exporter records the stereo pair, the left camera's JPEG and the detections" do
    config = OvcsMini.Vision.Composer.config(:target)
    wired = %{config | components: VisionCore.Components.wire_streams!(config.components)}

    for config <- [config, wired] do
      options = Keyword.fetch!(config.exporters, BagExporter) ++ [config: config]

      assert BagExporter.check(options) == :ok
      assert {:ok, specs} = VisionCore.Exporter.output_specs(BagExporter, options)
      outputs = Enum.map(specs, &elem(&1, 0))

      assert outputs == [
               {:stereo_frame, :left},
               {:stereo_frame, :right},
               {:camera_frame, :left, :half_jpeg},
               :stereo_pair,
               {:detections, :detection}
             ]

      assert Enum.map(outputs, &Preset.kind/1) == [:sides, :sides, :cameras, :pairs, :detections]

      for preset <- Preset.names(),
          do: assert(Preset.options(preset, config)[:cameras][:outputs] == [left: :half_jpeg])

      for output <- outputs,
          do: assert(VisionCore.Exporter.output_key(output, config), inspect(output))
    end
  end

  test "the left camera of its own is a second stream of the stereo unit's left capture, a JPEG at half the sensor mode, at most 30 a second" do
    config = OvcsMini.Vision.Composer.config(:target)
    camera = camera(config, :left)

    assert camera[:driver] == LibCameraStream
    assert camera[:stream_of] == :left
    assert camera[:max_hz] == 30

    assert camera[:outputs] == [
             half: [resolution: {1152, 648}, processor: :isp, send: false],
             half_jpeg: [from: :half, format: :jpeg, quality: 80]
           ]

    assert camera[:calibration_store_dir] == "/data/vision/calibration"
  end

  test "the vision core hands the stereo unit's left camera the left camera's outputs, and leaves the right one as it is" do
    config = OvcsMini.Vision.Composer.config(:target)
    camera = camera(config, :left)

    components = VisionCore.Components.wire_streams!(config.components)
    stereo = Keyword.fetch!(components, :stereo)

    assert stereo[:left][:outputs] == camera[:outputs]
    assert stereo[:left][:outputs_max_hz] == 30
    assert {:ok, _outputs} = LibCamera.capture_outputs(stereo[:left])
    refute Keyword.has_key?(stereo[:right], :outputs)
    assert camera(%{config | components: components}, :left)[:side_label] == "stereo/left"
  end

  test "the ROS 2 exporter publishes the left camera's JPEG apart from the stereo unit's left frames" do
    config = OvcsMini.Vision.Composer.config(:target)
    options = Keyword.fetch!(config.exporters, ZenohExporter)

    assert options[:cameras] == [names: [:left], outputs: [left: :half_jpeg]]

    assert VisionCore.Exporter.output_key({:camera_frame, :left, :half_jpeg}, config) ==
             {:camera_frame, LibCameraStream.name_for("left"), :half_jpeg}

    assert VisionCore.Exporter.output_key({:stereo_frame, :left}, config) ==
             {:camera_frame, LibCamera.name_for("stereo/left")}
  end

  test "the ROS 2 exporter's outputs are all produced by the configuration, as written and as wired" do
    config = OvcsMini.Vision.Composer.config(:target)
    wired = %{config | components: VisionCore.Components.wire_streams!(config.components)}

    for config <- [config, wired] do
      options = Keyword.fetch!(config.exporters, ZenohExporter) ++ [config: config]

      assert ZenohExporter.check(options) == :ok
      assert {:ok, specs} = VisionCore.Exporter.output_specs(ZenohExporter, options)
      assert {:camera_frame, :left, :half_jpeg} in Enum.map(specs, &elem(&1, 0))

      for {output, _max_hz} <- specs,
          do: assert(VisionCore.Exporter.output_key(output, config), inspect(output))
    end
  end
end
