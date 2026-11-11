defmodule VisionCore.DetectionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection

  test "the default pipeline's processes are registered under their modules" do
    assert Detection.server(Detection.Pipeline, :detection) == Detection.Pipeline
  end

  test "a named pipeline's processes are registered under their modules and its name" do
    assert Detection.server(Detection.Pipeline, :road_signs) == Detection.Pipeline.RoadSigns
  end

  test "the pipeline name of a detector's options, :detection without one" do
    assert Detection.pipeline_name(name: :road) == :road
    assert Detection.pipeline_name(backend: Detection.Backend.Stub) == :detection
  end

  test "the exporter output of a pipeline's detections, :detections for the default one" do
    assert Detection.output(:detection) == :detections
    assert Detection.output(:road) == {:detections, :road}
  end

  test "tells a valid pipeline name from an invalid one" do
    assert Detection.name?(:road_signs)
    refute Detection.name?(:stereo)
    refute Detection.name?(:"front-cam")
    refute Detection.name?("road")
  end

  test "takes a lowercase name of letters, digits and underscores" do
    for name <- [:detection, :road, :signs_2] do
      assert Detection.name!(name) == name
    end
  end

  test "refuses a name that is no ROS 2 parameter segment, or the stereo pipeline's, naming the rule" do
    for name <- [:"front-cam", :"front.cam", :Road, :"2nd", :stereo, "road"] do
      error = assert_raise ArgumentError, fn -> Detection.name!(name) end
      assert error.message =~ "^[a-z][a-z0-9_]*$"
      assert error.message =~ "not :stereo"
      assert error.message =~ inspect(name)
    end
  end
end
