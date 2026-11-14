defmodule VisionApiWeb.EndpointTest do
  use VisionApiWeb.ConnCase, async: true

  test "outside development, another origin's requests get no cross-origin approval",
       %{conn: conn} do
    conn = put_req_header(conn, "origin", "http://elsewhere.example")

    preflight =
      conn
      |> put_req_header("access-control-request-method", "POST")
      |> options("/api/parameter-saves")

    assert get_resp_header(preflight, "access-control-allow-origin") == []
    assert get_resp_header(get(conn, "/api/unknown"), "access-control-allow-origin") == []
  end

  describe "the dashboard socket" do
    defp open_socket(conn, origin) do
      conn
      |> put_req_header("origin", origin)
      |> get("/sockets/dashboard/websocket?vsn=2.0.0")
    end

    test "refuses a page of another origin", %{conn: conn} do
      assert open_socket(conn, "https://elsewhere.example").status == 403
      assert open_socket(conn, "https://#{conn.host}").status == 403
      assert open_socket(conn, "http://#{conn.host}:8080").status == 403
    end

    # Past the origin check, the test adapter's connection cannot be upgraded: a 400.
    test "takes the origin the request was sent to, a name or an address", %{conn: conn} do
      assert open_socket(conn, "http://#{conn.host}").status == 400

      conn = %{conn | host: "192.168.10.232"}
      assert open_socket(conn, "http://192.168.10.232").status == 400
    end
  end
end
