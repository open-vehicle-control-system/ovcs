defmodule VisionCore.ComponentsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Components

  # A unit that gives up exits :shutdown; restarting it would spend the vision core's own budget.
  test "the stereo and detection units are not restarted once they give up" do
    for component <- [:detector, :stereo] do
      assert [%{restart: :transient}] = Components.start(component, [])
    end
  end

  test "the heartbeat starts no process of its own: the ROS 2 exporter publishes it" do
    assert Components.start(:heartbeat, interval_ms: 500) == []
  end
end
