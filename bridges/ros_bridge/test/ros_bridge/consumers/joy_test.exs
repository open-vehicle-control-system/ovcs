defmodule RosBridge.Consumers.JoyTest do
  use ExUnit.Case, async: true

  alias RosBridge.Consumers.Joy

  test "topic/1 reads the topic out of an rmw_zenoh key" do
    assert Joy.topic("0/joy_wheel/sensor_msgs::msg::dds_::Joy_/RIHS01_abc") == "joy_wheel"
    assert Joy.topic("0/a/b/sensor_msgs::msg::dds_::Joy_/RIHS01_abc") == "a/b"
  end

  test "the sequence counts every sample and wraps into a byte" do
    assert Joy.next_sequence(0) == 1
    assert Joy.next_sequence(255) == 0
  end
end
