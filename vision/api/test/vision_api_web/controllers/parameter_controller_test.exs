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
end
