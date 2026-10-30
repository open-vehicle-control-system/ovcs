defmodule VisionApiWeb.ConfigurationControllerTest do
  use VisionApiWeb.ConnCase, async: false

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm) do
      %VisionCore.Config{
        zenoh_endpoint_ip: "127.0.0.1",
        node_name: "vision_test",
        components: [{:heartbeat, interval_ms: 5_000}]
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
                     "zenoh_endpoint_ip" => "127.0.0.1",
                     "node_name" => "vision_test",
                     "components" => [
                       %{"name" => "heartbeat", "options" => %{"interval_ms" => 5_000}}
                     ],
                     "preview" => []
                   }
                 },
                 "relationships" => %{}
               }
             }
    end
  end

  test "an unknown API path is a JSON 404", %{conn: conn} do
    assert json_response(get(conn, "/api/unknown"), 404) == %{
             "errors" => %{"detail" => "Not Found"}
           }
  end
end
