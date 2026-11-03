defmodule VisionCore.ComponentsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Components

  # A unit that gives up exits :shutdown; restarting it would spend the vision core's own budget.
  test "the stereo and detection units are not restarted once they give up" do
    for component <- [:detector, :stereo] do
      assert [%{restart: :transient}] = Components.start(component, [])
    end
  end

  test "the heartbeat and the simulator clock are not components: the ROS 2 exporter and the ros2: section own them" do
    for component <- [:heartbeat, :simulator_clock] do
      assert_raise FunctionClauseError, fn -> Components.start(component, []) end
    end
  end
end
