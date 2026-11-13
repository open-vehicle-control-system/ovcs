defmodule VisionCore.PipelinesTest do
  use ExUnit.Case, async: true

  alias VisionCore.Pipelines

  test "a pipeline's processes are registered under their modules and its name" do
    assert Pipelines.server(VisionCore.Detection.Pipeline, :detection) ==
             VisionCore.Detection.Pipeline.Detection

    assert Pipelines.server(VisionCore.Detection.Pipeline, :road_signs) ==
             VisionCore.Detection.Pipeline.RoadSigns
  end

  test "tells a valid pipeline name from an invalid one" do
    assert Pipelines.name?(:road_signs)
    refute Pipelines.name?(:stereo)
    refute Pipelines.name?(:left)
    refute Pipelines.name?(:device)
    assert Pipelines.name?(:detections)
    refute Pipelines.name?(:"front-cam")
    refute Pipelines.name?("road")
    refute Pipelines.name?(nil)
    refute Pipelines.name?(true)
    refute Pipelines.name?(false)
  end

  test "takes a lowercase name of letters, digits and underscores" do
    for name <- [:detection, :road, :signs_2] do
      assert Pipelines.name!(name) == name
    end
  end

  test "refuses a name that is no ROS 2 parameter segment, or the stereo pipeline's, naming the rule" do
    for name <- [:"front-cam", :"front.cam", :Road, :"2nd", :stereo, "road"] do
      error = assert_raise ArgumentError, fn -> Pipelines.name!(name) end
      assert error.message =~ "^[a-z][a-z0-9_]*$"
      assert error.message =~ "not one of :stereo"
      assert error.message =~ inspect(name)
    end
  end
end
