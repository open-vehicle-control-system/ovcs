defmodule VisionApiWeb.ParameterControllerTest do
  use VisionApiWeb.ParametersCase

  test "parameters carry their constraint, state, default and relationships", %{conn: conn} do
    assert %{
             "attributes" => %{
               "constraint" => %{"kind" => "range", "min" => 0, "max" => 78, "step" => nil},
               "applies" => "live",
               "state" => "builtin",
               "default" => 8,
               "value" => 8
             },
             "relationships" => %{"group" => %{"data" => %{"id" => "test.match"}}}
           } = parameter(conn, "test.match.p1")

    assert %{
             "relationships" => %{
               "greater-than" => %{"data" => %{"type" => "parameters", "id" => "test.match.p1"}}
             }
           } = parameter(conn, "test.match.p2")

    assert %{
             "attributes" => %{"state" => "automatic", "applies" => "live"},
             "relationships" => %{"controller" => %{"data" => %{"id" => "test.match.auto"}}}
           } = parameter(conn, "test.match.exposure")

    assert %{"attributes" => %{"applies" => "build", "constraint" => nil}} =
             parameter(conn, "test.match.width")
  end

  test "GET /api/parameters lists every parameter", %{conn: conn} do
    assert %{"data" => data, "meta" => %{"unsaved" => 0}} =
             json_response(get(conn, "/api/parameters"), 200)

    assert Enum.count(data, &String.starts_with?(&1["id"], "test.match.")) == 5
  end

  test "GET /api/parameters/:id answers 404 as an error object for an unknown id", %{conn: conn} do
    conn = get(conn, "/api/parameters/nope")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"errors" => [%{"status" => "404", "title" => "Not Found"}]} =
             json_response(conn, 404)
  end

  defp patch_value(conn, id, body) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch("/api/parameters/#{id}", Jason.encode!(body))
  end

  defp body(id, value),
    do: %{data: %{type: "parameters", id: id, attributes: %{value: value}}}

  defp refusal(detail) do
    %{
      "status" => "422",
      "title" => "Invalid value",
      "detail" => detail,
      "source" => %{"pointer" => "/data/attributes/value"}
    }
  end

  test "PATCH sets a value and answers the parameter, now unsaved", %{conn: conn} do
    conn = patch_value(conn, "test.match.p1", body("test.match.p1", 12))
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"data" => %{"attributes" => %{"value" => 12, "state" => "unsaved"}}} =
             json_response(conn, 200)

    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.match.p1")
  end

  test "PATCH refuses a value as a 422 error pointing at the value", %{conn: conn} do
    assert %{"errors" => [refusal("expected integer, got \"8\"")]} ==
             conn
             |> patch_value("test.match.p1", body("test.match.p1", "8"))
             |> json_response(422)

    assert %{"errors" => [refusal("must be above test.match.p1 (8)")]} ==
             conn
             |> patch_value("test.match.p2", body("test.match.p2", 8))
             |> json_response(422)

    assert %{"errors" => [refusal("fixed in the build")]} ==
             conn
             |> patch_value("test.match.width", body("test.match.width", 1))
             |> json_response(422)
  end

  test "PATCH answers 404 for an unknown parameter", %{conn: conn} do
    assert %{"errors" => [%{"status" => "404"}]} =
             conn |> patch_value("nope", body("nope", 1)) |> json_response(404)
  end

  test "PATCH answers 409 for another type or id, and 400 without a value", %{conn: conn} do
    id = "test.match.p1"
    wrong_type = %{data: %{type: "groups", id: id, attributes: %{value: 1}}}

    assert %{"errors" => [%{"status" => "409"}]} =
             conn |> patch_value(id, wrong_type) |> json_response(409)

    assert %{"errors" => [%{"status" => "409"}]} =
             conn |> patch_value(id, body("other", 1)) |> json_response(409)

    assert %{
             "errors" => [
               %{"status" => "400", "source" => %{"pointer" => "/data/attributes/value"}}
             ]
           } =
             conn
             |> patch_value(id, %{data: %{type: "parameters", id: id, attributes: %{}}})
             |> json_response(400)

    assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data"}}]} =
             conn |> patch_value(id, %{}) |> json_response(400)

    assert %{"attributes" => %{"state" => "builtin"}} = parameter(conn, id)
  end
end
