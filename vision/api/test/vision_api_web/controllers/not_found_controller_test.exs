defmodule VisionApiWeb.NotFoundControllerTest do
  use VisionApiWeb.ConnCase, async: true

  @media_type "application/vnd.api+json"

  test "an unknown API path answers a JSON:API 404, whatever the client accepts", %{conn: conn} do
    for accept <- [@media_type, "application/json", "text/html", nil] do
      conn = if accept, do: put_req_header(conn, "accept", accept), else: conn
      conn = get(conn, "/api/unknown")

      assert get_resp_header(conn, "content-type") == [@media_type]

      assert json_response(conn, 404) == %{
               "errors" => [
                 %{
                   "status" => "404",
                   "title" => "Not Found",
                   "detail" => "no route for GET /api/unknown"
                 }
               ]
             }
    end
  end

  test "another method on a known path answers 405, naming the methods it takes", %{conn: conn} do
    for {request, allow} <- [
          {&delete(&1, "/api/parameters/x"), "GET, PATCH"},
          {&post(&1, "/api/stages"), "GET"},
          {&get(&1, "/api/parameter-saves"), "POST"}
        ] do
      conn = request.(conn)

      assert get_resp_header(conn, "content-type") == [@media_type]
      assert get_resp_header(conn, "allow") == [allow]

      assert %{"errors" => [%{"status" => "405", "title" => "Method Not Allowed"}]} =
               json_response(conn, 405)
    end
  end

  test "a method no path takes answers the 404 of an unknown path", %{conn: conn} do
    conn = delete(conn, "/api/unknown")

    assert %{"errors" => [%{"status" => "404", "detail" => "no route for DELETE /api/unknown"}]} =
             json_response(conn, 404)
  end
end
