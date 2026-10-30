defmodule VisionCore.Ros2.ZenohClientLinkTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo
  alias Ros2Zenoh.StdMsgs.Msg.String, as: StringMessage
  alias VisionCore.Ros2.{Topics, ZenohClient}

  test "without a client the link is down, with no endpoint and no service" do
    assert %{connected: false, endpoint: nil, services: []} = ZenohClient.link()
  end

  describe "with a client" do
    setup do
      topics = start_supervised!(Topics)
      start_supervised!({ZenohClient, endpoint_ip: "127.0.0.1", node_name: "vision_test"})
      %{topics: topics}
    end

    test "names its node, its router endpoint and the services it answers, sorted" do
      :ok = ZenohClient.register_service("stereo/left/set_camera_info", SetCameraInfo)
      :ok = ZenohClient.register_service("/vision_test/set_parameters", SetCameraInfo)

      assert %{
               node_name: "vision_test",
               endpoint: "tcp/127.0.0.1:7447",
               services: [
                 %{name: "/stereo/left/set_camera_info", type: "sensor_msgs/srv/SetCameraInfo"},
                 %{name: "/vision_test/set_parameters", type: "sensor_msgs/srv/SetCameraInfo"}
               ]
             } = ZenohClient.link()
    end

    test "counts each publish under its topic", %{topics: topics} do
      ZenohClient.publish("ovcs_heartbeat", StringMessage, %StringMessage{data: "test"})
      send(topics, :tick)
      :sys.get_state(topics)

      assert [%{name: "/ovcs_heartbeat", type: "std_msgs/msg/String"}] = Topics.topics()
    end
  end
end
