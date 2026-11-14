defmodule VisionApiWeb.JsonApiTest do
  use VisionApiWeb.ConnCase, async: false

  @media_type "application/vnd.api+json"
  @json [{"content-type", @media_type}]

  defp send_request(conn, method, path) do
    conn =
      Enum.reduce(@json, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    dispatch(conn, @endpoint, method, path, ~s({"data": {"type": "x"}}))
  end

  describe "an id in the path that is not UTF-8" do
    for {method, path} <- [
          {:get, "/api/parameters/%FF"},
          {:patch, "/api/parameters/%FF"},
          {:get, "/api/calibrations/%FF"},
          {:get, "/api/saved-calibrations/%FF"},
          {:patch, "/api/saved-calibrations/%FF"},
          {:delete, "/api/saved-calibrations/%FF"},
          {:post, "/api/exporters/%FF/actions/export"},
          {:post, "/api/exporters/debug/actions/%C3%28"}
        ] do
      test "answers a JSON:API 400 to #{method |> to_string() |> String.upcase()} #{path}",
           %{conn: conn} do
        conn = send_request(conn, unquote(method), unquote(path))

        assert get_resp_header(conn, "content-type") == [@media_type]

        assert %{"errors" => [%{"status" => "400", "title" => "Bad Request", "detail" => detail}]} =
                 json_response(conn, 400)

        assert detail == "the path is not valid UTF-8"
      end
    end
  end

  describe "a query parameter the route does not support" do
    for path <- [
          "/api/parameters",
          "/api/parameters/stereo.disparity.p1",
          "/api/depth-preview",
          "/api/configuration",
          "/api/firmware",
          "/api/board",
          "/api/exporters",
          "/api/calibrations",
          "/api/calibrations/unit",
          "/api/saved-calibrations",
          "/api/saved-calibrations/1"
        ] do
      test "GET #{path} answers 400 to an include, naming it", %{conn: conn} do
        conn = get(conn, unquote(path) <> "?include=stage")

        assert get_resp_header(conn, "content-type") == [@media_type]

        assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
                 json_response(conn, 400)
      end
    end

    for path <- ["/api/stages", "/api/ros2-node", "/api/parameters", "/api/saved-calibrations"] do
      test "GET #{path} answers 400 to a sort, naming it", %{conn: conn} do
        conn = get(conn, unquote(path) <> "?sort=name")

        assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "sort"}}]} =
                 json_response(conn, 400)
      end
    end

    test "a write answers 400 to an include too, and changes nothing", %{conn: conn} do
      conn = send_request(conn, :post, "/api/parameter-saves?include=parameters")

      assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
               json_response(conn, 400)
    end
  end
end
