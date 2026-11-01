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
end
