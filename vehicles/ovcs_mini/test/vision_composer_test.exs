defmodule OvcsMini.VisionComposerTest do
  use ExUnit.Case, async: true

  test "the stereo unit matches at most 20 pairs a second, a value its vision parameter takes" do
    %VisionCore.Config{components: components} = OvcsMini.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(components, :stereo)

    assert %{max_hz: 20.0, pair_tolerance_ms: 5} =
             VisionCore.Settings.init!(VisionCore.Stereo.Pairer.setting_specs(), stereo)

    assert {:ok, _cameras} =
             VisionCore.Stereo.Supervisor.camera_options(OvcsMini.Vision.Composer.config(:target))
  end

  test "the bag exporter records the stereo pair and the detections" do
    config = OvcsMini.Vision.Composer.config(:target)
    options = Keyword.fetch!(config.exporters, VisionCore.Ros2.BagExporter) ++ [config: config]

    assert VisionCore.Ros2.BagExporter.check(options) == :ok
    assert {:ok, specs} = VisionCore.Exporter.output_specs(VisionCore.Ros2.BagExporter, options)

    assert Enum.map(specs, &elem(&1, 0)) == [
             {:camera_frame, :left},
             {:camera_frame, :right},
             :stereo_pair,
             {:detections, :detection}
           ]
  end
end
