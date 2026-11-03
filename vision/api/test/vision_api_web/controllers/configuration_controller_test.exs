defmodule VisionApiWeb.ConfigurationControllerTest do
  use VisionApiWeb.ConnCase, async: false

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm) do
      %VisionCore.Config{
        ros2: [zenoh_endpoint_ip: "127.0.0.1", node_name: "vision_test"],
        exporters: [{VisionCore.Ros2.Exporter, heartbeat: [interval_ms: 5_000]}]
      }
    end
  end

  defp start_pipeline(_context) do
    Application.stop(:vision_core)
    Application.put_env(:vision_core, :vehicle, Composer)
    {:ok, _apps} = Application.ensure_all_started(:vision_core)

    on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.ensure_all_started(:vision_core)
    end)
  end

  describe "with a running pipeline" do
    setup :start_pipeline

    test "GET /api/configuration answers the active composer config", %{conn: conn} do
      conn = get(conn, "/api/configuration")
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

      assert json_response(conn, 200) == %{
               "data" => %{
                 "type" => "configurations",
                 "id" => "current",
                 "attributes" => %{
                   "composer" => %{
                     "ros2" => %{"zenoh_endpoint_ip" => "127.0.0.1", "node_name" => "vision_test"},
                     "components" => [],
                     "exporters" => [
                       %{
                         "module" => "VisionCore.Ros2.Exporter",
                         "options" => %{"heartbeat" => %{"interval_ms" => 5_000}}
                       }
                     ],
                     "preview" => []
                   }
                 }
               }
             }
    end
  end
end
