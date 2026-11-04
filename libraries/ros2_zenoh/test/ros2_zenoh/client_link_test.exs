defmodule Ros2Zenoh.ClientLinkTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Ros2Zenoh.Client
  alias Ros2Zenoh.SensorMsgs.Msg.CompressedImage
  alias Ros2Zenoh.SensorMsgs.Srv.SetCameraInfo

  test "without a client there is no link" do
    assert Client.link() == nil
  end

  describe "with a client" do
    setup do
      start_supervised!({Client, endpoint_ip: "127.0.0.1", node_name: "ros2_zenoh_test"})
      :ok
    end

    test "names its node, its router endpoint and the services it answers, sorted" do
      :ok = Client.register_service("stereo/left/set_camera_info", SetCameraInfo)
      :ok = Client.register_service("/ros2_zenoh_test/set_parameters", SetCameraInfo)

      assert %{
               node_name: "ros2_zenoh_test",
               domain_id: 0,
               endpoint: "tcp/127.0.0.1:7447",
               services: [
                 %{
                   name: "/ros2_zenoh_test/set_parameters",
                   type: "sensor_msgs/srv/SetCameraInfo"
                 },
                 %{name: "/stereo/left/set_camera_info", type: "sensor_msgs/srv/SetCameraInfo"}
               ]
             } = Client.link()
    end

    test "forgets a service once its handler exits" do
      handler =
        spawn(fn ->
          :ok = Client.register_service("stereo/right/set_camera_info", SetCameraInfo)

          receive do
            :stop -> :ok
          end
        end)

      Process.sleep(50)
      assert [%{name: "/stereo/right/set_camera_info"}] = Client.link().services

      send(handler, :stop)
      Process.sleep(50)
      assert Client.link().services == []
    end
  end

  describe "while its router does not answer" do
    setup do
      start_supervised!(
        {Client,
         endpoint_ip: "192.0.2.1",
         node_name: "ros2_zenoh_test",
         open_session: fn _endpoint_ip -> Process.sleep(:infinity) end}
      )

      :ok
    end

    test "answers at once, keeping subscriptions and services for the session to come" do
      assert Client.node_name() == "ros2_zenoh_test"
      assert :ok = Client.register_service("stereo/left/set_camera_info", SetCameraInfo)
      assert :ok = Client.subscribe("stereo/left/image_raw/compressed", CompressedImage)

      assert %{connected: false, services: [%{name: "/stereo/left/set_camera_info"}]} =
               Client.link()
    end
  end
end
