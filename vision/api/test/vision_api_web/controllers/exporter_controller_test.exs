defmodule VisionApiWeb.ExporterControllerTest do
  use VisionApiWeb.ParametersCase

  test "GET /api/exporters lists the unit's exporters, then the API that answers", %{conn: conn} do
    conn = get(conn, "/api/exporters")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"data" => [ros2, api]} = json_response(conn, 200)

    assert %{
             "type" => "exporters",
             "id" => "ros2",
             "attributes" => %{
               "name" => "ROS 2",
               "module" => "VisionCore.Ros2.Exporter",
               "status" => status,
               "outputs" => [%{"name" => "detections", "maxHz" => nil}]
             }
           } = ros2

    # The link's: connected while a Zenoh router runs where the tests do.
    assert status in [
             %{"level" => "ok", "detail" => "Connected"},
             %{"level" => "warning", "detail" => "Disconnected"}
           ]

    assert api == %{
             "type" => "exporters",
             "id" => "api",
             "attributes" => %{
               "name" => "API",
               "module" => "VisionApiWeb.Endpoint",
               "status" => %{"level" => "ok", "detail" => "Answering"},
               "outputs" => []
             }
           }
  end
end

defmodule VisionApiWeb.ExporterControllerWithoutPipelineTest do
  use VisionApiWeb.ConnCase, async: false

  test "GET /api/exporters lists the API alone on a unit whose pipeline does not run",
       %{conn: conn} do
    assert %{"data" => [%{"id" => "api"}]} =
             conn |> get("/api/exporters") |> json_response(200)
  end
end

defmodule VisionApiWeb.ExporterJSONTest do
  use ExUnit.Case, async: true

  alias VisionApiWeb.ExporterJSON

  test "names each output, a camera's with its side, with the most values it takes a second" do
    exporter = %{
      id: "recorder",
      name: "Recorder",
      module: MyCar.Recorder,
      status: {:off, "Not running"},
      outputs: [
        %{output: :stereo_pair, max_hz: 2},
        %{output: {:camera_frame, :left}, max_hz: nil},
        %{output: :detections, max_hz: nil}
      ]
    }

    assert %{data: [%{id: "recorder", attributes: attributes}]} =
             ExporterJSON.index(%{exporters: [exporter]})

    assert attributes == %{
             name: "Recorder",
             module: "MyCar.Recorder",
             status: %{level: "off", detail: "Not running"},
             outputs: [
               %{name: "stereo_pair", maxHz: 2},
               %{name: "camera_frame:left", maxHz: nil},
               %{name: "detections", maxHz: nil}
             ]
           }
  end
end
