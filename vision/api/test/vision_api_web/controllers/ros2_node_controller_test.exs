defmodule VisionApiWeb.Ros2NodeControllerTest do
  use VisionApiWeb.ParametersCase

  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo

  setup do
    VisionCore.Ros2.Topics.count("stereo/left/camera_info", CameraInfo)
    send(VisionCore.Ros2.Topics, :tick)
    :sys.get_state(VisionCore.Ros2.Topics)
    :ok
  end

  defp ros2_node(conn, query \\ "") do
    conn = get(conn, "/api/ros2-node" <> query)
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]
    json_response(conn, 200)
  end

  test "GET /api/ros2-node describes the node with linkage to its topics and services",
       %{conn: conn} do
    assert %{
             "data" => %{
               "type" => "ros2-nodes",
               "id" => "vision_test",
               "attributes" => %{
                 "name" => "vision_test",
                 "zenohEndpoint" => "tcp/127.0.0.1:7447",
                 "connected" => connected
               },
               "relationships" => %{
                 "topics" => %{
                   "data" => [%{"type" => "ros2-topics", "id" => "/stereo/left/camera_info"}]
                 },
                 "services" => %{"data" => services}
               }
             }
           } = body = ros2_node(conn)

    assert is_boolean(connected)
    assert %{"type" => "ros2-services", "id" => "/vision_test/list_parameters"} in services
    refute Map.has_key?(body, "included")
  end

  test "GET /api/ros2-node?include=topics,services includes both", %{conn: conn} do
    %{"included" => included} = ros2_node(conn, "?include=topics,services")

    assert %{
             "type" => "ros2-topics",
             "id" => "/stereo/left/camera_info",
             "attributes" => %{
               "name" => "/stereo/left/camera_info",
               "messageType" => "sensor_msgs/msg/CameraInfo",
               "rateHz" => rate_hz
             }
           } = Enum.find(included, &(&1["type"] == "ros2-topics"))

    assert is_number(rate_hz)

    assert %{
             "type" => "ros2-services",
             "id" => "/vision_test/list_parameters",
             "attributes" => %{
               "name" => "/vision_test/list_parameters",
               "serviceType" => "rcl_interfaces/srv/ListParameters"
             }
           } in included
  end

  test "GET /api/ros2-node includes each relationship alone", %{conn: conn} do
    %{"included" => topics} = ros2_node(conn, "?include=topics")
    assert Enum.all?(topics, &(&1["type"] == "ros2-topics"))

    %{"included" => services} = ros2_node(conn, "?include=services")
    assert services != [] and Enum.all?(services, &(&1["type"] == "ros2-services"))
  end

  test "GET /api/ros2-node answers 400 for an include it does not support", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
             conn |> get("/api/ros2-node?include=parameters") |> json_response(400)
  end

  test "GET /api/ros2-node without the vision core answers the node as disconnected",
       %{conn: conn} do
    Application.stop(:vision_core)

    assert %{
             "data" => %{
               "attributes" => %{"connected" => false, "zenohEndpoint" => nil},
               "relationships" => %{"topics" => %{"data" => []}, "services" => %{"data" => []}}
             }
           } = ros2_node(conn)
  end
end
