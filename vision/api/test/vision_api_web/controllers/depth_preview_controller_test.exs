defmodule VisionApiWeb.DepthPreviewControllerTest do
  use VisionApiWeb.ConnCase, async: false

  @path "/api/depth-preview"

  defp start_preview(_context) do
    start_supervised!({VisionCore.Preview, config: %VisionCore.Config{}, depth_range_m: 6.0})
    :ok
  end

  defp patch_range(conn, data) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(@path, Jason.encode!(%{data: data}))
  end

  defp document(range),
    do: %{type: "depth-previews", id: "current", attributes: %{colourRangeM: range}}

  describe "while the previews run" do
    setup :start_preview

    test "GET /api/depth-preview answers the colour range in force", %{conn: conn} do
      conn = get(conn, @path)
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

      assert json_response(conn, 200) == %{
               "data" => %{
                 "type" => "depth-previews",
                 "id" => "current",
                 "attributes" => %{"colourRangeM" => 6.0}
               }
             }
    end

    test "PATCH /api/depth-preview sets the colour range and answers the resource", %{conn: conn} do
      conn = patch_range(conn, document(8.5))

      assert %{"data" => %{"attributes" => %{"colourRangeM" => 8.5}}} = json_response(conn, 200)
      assert VisionCore.Preview.options().depth_range_m == 8.5
    end

    test "PATCH /api/depth-preview refuses a range the previews refuse as a 422 pointing at it",
         %{conn: conn} do
      for range <- [-1, 51, "far", nil] do
        assert %{
                 "errors" => [
                   %{
                     "status" => "422",
                     "source" => %{"pointer" => "/data/attributes/colourRangeM"}
                   }
                 ]
               } = conn |> patch_range(document(range)) |> json_response(422)
      end

      assert VisionCore.Preview.options().depth_range_m == 6.0
    end

    test "PATCH /api/depth-preview answers 409 for another type or id, and 400 without a range",
         %{conn: conn} do
      refusals = [
        {%{document(8) | type: "previews"}, 409, "/data/type"},
        {%{document(8) | id: "depth"}, 409, "/data/id"},
        {%{type: "depth-previews", id: "current"}, 400, "/data/attributes/colourRangeM"},
        {%{type: "depth-previews", id: "current", attributes: [8]}, 400,
         "/data/attributes/colourRangeM"}
      ]

      for {data, status, pointer} <- refusals do
        assert %{"errors" => [%{"source" => %{"pointer" => ^pointer}}]} =
                 conn |> patch_range(data) |> json_response(status)
      end

      assert VisionCore.Preview.options().depth_range_m == 6.0
    end

    test "PATCH /api/depth-preview sent as a form answers 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> patch(@path, "data[attributes][colourRangeM]=8")

      assert %{"errors" => [%{"status" => "400"}]} = json_response(conn, 400)
    end
  end

  test "GET and PATCH /api/depth-preview answer 503 while the previews do not run", %{conn: conn} do
    Application.stop(:vision_core)
    on_exit(fn -> Application.ensure_all_started(:vision_core) end)

    assert %{"errors" => [%{"status" => "503"}]} = conn |> get(@path) |> json_response(503)

    assert %{"errors" => [%{"status" => "503"}]} =
             conn |> patch_range(document(8)) |> json_response(503)
  end
end
