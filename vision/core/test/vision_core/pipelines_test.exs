defmodule VisionCore.PipelinesTest do
  use ExUnit.Case, async: false

  alias VisionCore.Pipelines

  test "a pipeline's process is found under its module and its pipeline's name" do
    server = Pipelines.server(__MODULE__, :road_signs)
    assert GenServer.whereis(server) == nil

    {:ok, process} = Agent.start_link(fn -> :held end, name: server)

    assert GenServer.whereis(server) == process
    assert Agent.get(server, & &1) == :held
    assert GenServer.whereis(Pipelines.server(__MODULE__, :road)) == nil
  end

  test "tells a valid pipeline name from an invalid one" do
    assert Pipelines.name?(:road_signs)
    refute Pipelines.name?(:stereo)
    refute Pipelines.name?(:left)
    assert Pipelines.name?(:device)
    assert Pipelines.name?(:detections)
    assert Pipelines.name?(:live)
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
