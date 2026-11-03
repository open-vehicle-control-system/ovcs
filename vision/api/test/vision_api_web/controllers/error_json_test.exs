defmodule VisionApiWeb.ErrorJSONTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  test "an error raised outside the controllers is a list of JSON:API error objects" do
    assert VisionApiWeb.ErrorJSON.render("500.json", %{}) == %{
             errors: [%{status: "500", title: "Internal Server Error"}]
           }
  end

  test "a request the vision core cannot answer gets that list, whatever the client accepts",
       %{conn: conn} do
    Application.stop(:vision_core)
    on_exit(fn -> Application.ensure_all_started(:vision_core) end)

    {500, _headers, body} =
      assert_error_sent(500, fn ->
        conn |> put_req_header("accept", "application/vnd.api+json") |> get("/api/parameters")
      end)

    assert Jason.decode!(body) == %{
             "errors" => [%{"status" => "500", "title" => "Internal Server Error"}]
           }
  end
end
