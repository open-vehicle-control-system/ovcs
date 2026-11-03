defmodule VisionCore.ExporterTest do
  use ExUnit.Case, async: true

  alias VisionCore.Exporter

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp config(components), do: %VisionCore.Config{components: components}

  test "an output resolves to the key its producer in the configuration publishes under" do
    config = config([{:stereo, driver: Camera, left: [], right: []}, :hailo_detector])

    assert Exporter.output_key(:stereo_pair, config) == {:stereo_pair, VisionCore.Stereo.Pipeline}

    assert Exporter.output_key({:camera_frame, :left}, config) ==
             {:camera_frame, Camera.name_for("left")}

    assert Exporter.output_key({:camera_frame, :right}, config) ==
             {:camera_frame, Camera.name_for("right")}

    assert Exporter.output_key(:detections, config) ==
             {:detections, VisionCore.Detection.Pipeline}
  end

  test "every detector component produces detections" do
    for detector <- [:detector, {:detector, boxes: []}, :hailo_detector, {:hailo_detector, []}] do
      assert Exporter.output_key(:detections, config([detector])) ==
               {:detections, VisionCore.Detection.Pipeline}
    end
  end

  test "an output no component of the configuration produces has no key" do
    for output <- [:stereo_pair, {:camera_frame, :left}, {:camera_frame, :right}, :detections] do
      assert Exporter.output_key(output, config([])) == nil
      assert Exporter.output_key(output, nil) == nil
    end
  end
end
