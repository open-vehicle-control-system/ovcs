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
               "outputs" => [],
               "actions" => []
             }
           } = ros2

    refute Map.has_key?(ros2["attributes"], "status")

    assert api == %{
             "type" => "exporters",
             "id" => "api",
             "attributes" => %{
               "name" => "API",
               "module" => "VisionApiWeb.Endpoint",
               "outputs" => [],
               "actions" => []
             }
           }
  end
end

defmodule VisionApiWeb.ExporterControllerWithUnitTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  # Names the stereo unit's cameras, which do not run.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # A camera of its own that captures nothing.
  defmodule NamedCamera do
    def name_for(label), do: Module.concat(__MODULE__, label)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def start_link(_opts), do: {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
  end

  test "GET /api/exporters gives each output of the API the most values its channel carries a second",
       %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{
      components: [
        {:stereo, driver: Camera, left: [], right: []},
        {:camera, name: :hq, driver: NamedCamera},
        {:detector, backend: VisionCore.Detection.Backend.Stub, max_hz: 4},
        {:detector, name: :road, backend: VisionCore.Detection.Backend.Stub, max_hz: 2},
        {:detector,
         name: :hq_people,
         backend: VisionCore.Detection.Backend.Stub,
         source: {:camera, :hq},
         max_hz: 3},
        {:segmenter,
         name: :road_surface,
         backend: VisionCore.Segmentation.Backend.Stub,
         source: {:camera, :hq},
         max_hz: 1},
        # Left down: its source is none a detection pipeline takes.
        {:detector, name: :mistyped, backend: VisionCore.Detection.Backend.Stub, source: :hq},
        # Left down: a segmentation pipeline needs a camera.
        {:segmenter, name: :sourceless, backend: VisionCore.Segmentation.Backend.Stub}
      ],
      preview: [max_hz: 5]
    })

    assert %{"data" => [%{"id" => "api", "attributes" => %{"outputs" => outputs}}]} =
             conn |> get("/api/exporters") |> json_response(200)

    assert outputs == [
             %{"name" => "camera_frame:left", "maxHz" => 5},
             %{"name" => "camera_frame:right", "maxHz" => 5},
             %{"name" => "stereo_pair", "maxHz" => 5},
             %{"name" => "camera_frame:hq", "maxHz" => 5},
             %{"name" => "detections:detection", "maxHz" => 4, "source" => "left"},
             %{"name" => "detections:road", "maxHz" => 2, "source" => "left"},
             %{"name" => "detections:hq_people", "maxHz" => 3, "source" => "hq"},
             %{"name" => "segmentation:road_surface", "maxHz" => 1, "source" => "hq"}
           ]
  end
end

defmodule VisionApiWeb.ExporterControllerWithVideoTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  test "GET /api/exporters lists each video the API relays after its camera's frames, unbounded",
       %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{
      components: [
        {:camera,
         name: :hq,
         driver: VisionCore.Camera.V4L2Single,
         csiphy: 2,
         outputs: [
           full: [resolution: {2028, 1520}, processor: :cpu, send: false],
           half: [resolution: {1014, 760}, from: :full],
           full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
         ]}
      ],
      preview: [max_hz: 5, videos: [hq: :full_h264]]
    })

    assert %{"data" => [%{"id" => "api", "attributes" => %{"outputs" => outputs}}]} =
             conn |> get("/api/exporters") |> json_response(200)

    assert outputs == [
             %{"name" => "camera_frame:hq", "maxHz" => 5},
             %{"name" => "camera_video:hq:full_h264", "maxHz" => nil}
           ]
  end

  test "GET /api/exporters lists the video of a camera that sends no image, without camera frames",
       %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{
      components: [
        {:camera,
         name: :hq,
         driver: VisionCore.Camera.V4L2Single,
         csiphy: 2,
         outputs: [
           full: [resolution: {2028, 1520}, processor: :cpu, send: false],
           full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
         ]}
      ],
      preview: [max_hz: 5, videos: [hq: :full_h264]]
    })

    assert %{"data" => [%{"id" => "api", "attributes" => %{"outputs" => outputs}}]} =
             conn |> get("/api/exporters") |> json_response(200)

    assert outputs == [%{"name" => "camera_video:hq:full_h264", "maxHz" => nil}]
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

  test "names each output, a camera's with its side and a named pipeline's with its name, with the most values it takes a second and the source it has" do
    exporter = %{
      id: "recorder",
      name: "Recorder",
      module: MyCar.Recorder,
      status: {:off, "Not running"},
      outputs: [
        %{output: :stereo_pair, max_hz: 2},
        %{output: {:camera_frame, :left}, max_hz: nil},
        %{output: {:camera_frame, :hq, :inference}, max_hz: 10},
        %{output: {:detections, :detection}, max_hz: nil},
        %{output: {:detections, :road}, max_hz: 3, source: "hq"},
        %{output: {:segmentation, :lanes}, max_hz: 5, source: "hq"}
      ],
      actions: [%{name: :export, label: "Export", description: "Writes a zip."}]
    }

    assert %{data: [%{id: "recorder", attributes: attributes}]} =
             ExporterJSON.index(%{exporters: [exporter]})

    assert attributes == %{
             name: "Recorder",
             module: "MyCar.Recorder",
             outputs: [
               %{name: "stereo_pair", maxHz: 2},
               %{name: "camera_frame:left", maxHz: nil},
               %{name: "camera_frame:hq:inference", maxHz: 10},
               %{name: "detections:detection", maxHz: nil},
               %{name: "detections:road", maxHz: 3, source: "hq"},
               %{name: "segmentation:lanes", maxHz: 5, source: "hq"}
             ],
             actions: [%{name: "export", label: "Export", description: "Writes a zip."}]
           }
  end
end
