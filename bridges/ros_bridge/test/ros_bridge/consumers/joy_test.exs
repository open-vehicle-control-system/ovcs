defmodule RosBridge.Consumers.JoyTest do
  use ExUnit.Case, async: true

  alias RosBridge.Consumers.Joy

  test "topic/1 reads the topic out of an rmw_zenoh key" do
    assert Joy.topic("0/joy_wheel/sensor_msgs::msg::dds_::Joy_/RIHS01_abc") == "joy_wheel"
    assert Joy.topic("0/a/b/sensor_msgs::msg::dds_::Joy_/RIHS01_abc") == "a/b"
  end

  describe "gear/3" do
    test "a lever in a gear sets the direction and leaves the throttle" do
      assert Joy.gear(:backward, 0.5, "forward") == {0.5, "backward"}
      assert Joy.gear(:forward, 0.5, "backward") == {0.5, "forward"}
    end

    test "neutral only brakes and holds the direction" do
      assert Joy.gear(:neutral, 0.5, "backward") == {0.0, "backward"}
      assert Joy.gear(:neutral, -0.5, "backward") == {-0.5, "backward"}
    end

    test "a profile without a lever drives forward" do
      assert Joy.gear(nil, 0.5, "backward") == {0.5, "forward"}
    end
  end

  test "the sequence counts every sample and wraps into a byte" do
    assert Joy.next_sequence(0) == 1
    assert Joy.next_sequence(255) == 0
  end
end
