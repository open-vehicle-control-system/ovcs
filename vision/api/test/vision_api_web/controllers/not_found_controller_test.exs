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

  test "another method on a known path answers the same 404", %{conn: conn} do
    conn = conn |> put_req_header("accept", @media_type) |> delete("/api/parameters/x")

    assert %{
             "errors" => [
               %{"status" => "404", "detail" => "no route for DELETE /api/parameters/x"}
             ]
           } =
             json_response(conn, 404)
  end
end
