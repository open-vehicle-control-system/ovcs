defmodule VisionCore.DetectionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection

  test "the pipeline name of a detector's options, :detection without one" do
    assert Detection.pipeline_name(name: :road) == :road
    assert Detection.pipeline_name(backend: Detection.Backend.Stub) == :detection
  end

  test "the exporter output of a pipeline's detections, :detections for the default one" do
    assert Detection.output(:detection) == :detections
    assert Detection.output(:road) == {:detections, :road}
  end
end
