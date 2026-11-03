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

  test "lists no encode failure for a topic that has none", %{topics: pid} do
    Topics.count("stereo/depth/camera_info", CameraInfo)
    tick(pid)

    assert [%{name: "/stereo/depth/camera_info", encode_failures: 0}] = Topics.topics()
  end

  test "counts the messages that could not be encoded apart from the publishes", %{topics: pid} do
    Topics.count("stereo/points", CameraInfo)
    Topics.count_encode_failure("stereo/points", CameraInfo)
    Topics.count_encode_failure("/stereo/points", CameraInfo)
    tick(pid)

    assert [%{name: "/stereo/points", encode_failures: 2}] = Topics.topics()

    tick(pid)
    assert [%{name: "/stereo/points", rate_hz: +0.0, encode_failures: 2}] = Topics.topics()
  end

  test "lists a topic whose every message failed, at no rate", %{topics: pid} do
    assert Topics.count_encode_failure("stereo/points", CameraInfo) == :ok
    tick(pid)

    assert [
             %{
               name: "/stereo/points",
               type: "sensor_msgs/msg/CameraInfo",
               rate_hz: +0.0,
               encode_failures: 1
             }
           ] = Topics.topics()
  end

  test "counting without the table running is a no-op" do
    stop_supervised!(Topics)

    assert Topics.count("stereo/points", CameraInfo) == :ok
    assert Topics.count_encode_failure("stereo/points", CameraInfo) == :ok
    assert Topics.topics() == []
  end
end
