defmodule VisionApiWeb.ErrorJSONTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  test "an error raised outside the controllers is a list of JSON:API error objects" do
    assert VisionApiWeb.ErrorJSON.render("500.json", %{}) == %{
             errors: [%{status: "500", title: "Internal Server Error"}]
           }
  end

  defp content_type(headers), do: List.keyfind(headers, "content-type", 0)

  test "a body that is not JSON gets a JSON:API 400 saying so", %{conn: conn} do
    {400, headers, body} =
      assert_error_sent(400, fn ->
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/parameters/test.disparity.p1", "{")
      end)

    assert content_type(headers) == {"content-type", "application/vnd.api+json"}

    assert %{"errors" => [%{"status" => "400", "title" => "Bad Request", "detail" => detail}]} =
             Jason.decode!(body)

    assert detail =~ "malformed"
  end

  test "a client that accepts no JSON gets a JSON:API 406 saying so", %{conn: conn} do
    {406, headers, body} =
      assert_error_sent(406, fn ->
        conn |> put_req_header("accept", "text/html") |> get("/api/parameters")
      end)

    assert content_type(headers) == {"content-type", "application/vnd.api+json"}

    assert %{"errors" => [%{"status" => "406", "title" => "Not Acceptable", "detail" => detail}]} =
             Jason.decode!(body)

    assert detail =~ "application/vnd.api+json"
  end
end
