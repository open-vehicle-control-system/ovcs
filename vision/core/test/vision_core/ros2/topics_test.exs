defmodule VisionCore.Ros2.TopicsTest do
  use ExUnit.Case, async: false

  alias Ros2Zenoh.SensorMsgs.Msg.{CameraInfo, CompressedImage}
  alias VisionCore.Ros2.Topics

  setup do
    pid = start_supervised!(Topics)
    %{topics: pid}
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  test "lists no topic before any publish" do
    assert Topics.topics() == []
  end

  test "lists each counted topic by its full name and ROS type, sorted by name", %{topics: pid} do
    Topics.count("stereo/left/image_raw/compressed", CompressedImage)
    Topics.count("/stereo/left/camera_info", CameraInfo)
    tick(pid)

    assert [
             %{name: "/stereo/left/camera_info", type: "sensor_msgs/msg/CameraInfo"},
             %{
               name: "/stereo/left/image_raw/compressed",
               type: "sensor_msgs/msg/CompressedImage"
             }
           ] = Topics.topics()
  end

  test "turns the counts of each tick into a rate per second", %{topics: pid} do
    for _ <- 1..3, do: Topics.count("stereo/depth/camera_info", CameraInfo)
    tick(pid)
    [%{rate_hz: first}] = Topics.topics()
    assert first > 0

    tick(pid)
    assert [%{rate_hz: +0.0}] = Topics.topics()
  end

  test "names a module without a DDS type by its module name", %{topics: pid} do
    Topics.count("plain", String)
    tick(pid)

    assert [%{name: "/plain", type: "String"}] = Topics.topics()
  end

  test "counting without the table running is a no-op" do
    stop_supervised!(Topics)

    assert Topics.count("stereo/points", CameraInfo) == :ok
    assert Topics.topics() == []
  end
end
