defmodule VisionApiWeb.ParameterResetControllerTest do
  use VisionApiWeb.ParametersCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/parameter-resets", "parameter-resets")

  defp target(type, id),
    do: %{type: "parameter-resets", relationships: %{target: %{data: %{type: type, id: id}}}}

  test "POST /api/parameter-resets resets a parameter, a stage, or everything without a target",
       %{conn: conn} do
    set("test.disparity.p1", 12)
    set("test.disparity.p2", 70)

    assert %{"data" => %{"type" => "parameter-resets", "attributes" => %{"parameters" => ids}}} =
             conn
             |> post_document("/api/parameter-resets", target("parameters", "test.disparity.p1"))
             |> json_response(201)

    assert ids == ["test.disparity.p1"]
    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.disparity.p1")

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.disparity.p2"]}}} =
             conn
             |> post_document("/api/parameter-resets", target("stages", "test.disparity"))
             |> json_response(201)

    set("test.disparity.p1", 12)

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.disparity.p1"]}}} =
             conn
             |> post_document("/api/parameter-resets", %{type: "parameter-resets"})
             |> json_response(201)
  end

  test "POST /api/parameter-resets answers 404 for an unknown target", %{conn: conn} do
    for {type, id} <- [{"parameters", "nope"}, {"stages", "nope"}] do
      assert %{"errors" => [%{"status" => "404"}]} =
               conn
               |> post_document("/api/parameter-resets", target(type, id))
               |> json_response(404)
    end
  end

  test "POST /api/parameter-resets answers 422 when an owner refuses, and 400 for a bad target",
       %{conn: conn} do
    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.stubborn",
          name: "Stubborn",
          summary: "Refuses to be set.",
          kind: :component,
          pipeline: :detection,
          position: 9,
          parameters: [
            %{
              name: "level",
              type: :integer,
              default: 1,
              get: fn -> 5 end,
              set: fn _value -> {:error, "owner is busy"} end
            }
          ]
        }
      ])

    assert %{"errors" => [error]} =
             conn
             |> post_document(
               "/api/parameter-resets",
               target("parameters", "test.stubborn.level")
             )
             |> json_response(422)

    assert %{"status" => "422", "title" => "Not reset", "detail" => "test.stubborn.level: " <> _} =
             error

    refute Map.has_key?(error, "source")

    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post_document("/api/parameter-resets", target("widgets", "x"))
             |> json_response(400)
  end

  test "a reset sent in the query string, as another site's page can, is refused",
       %{conn: conn} do
    set("test.disparity.p1", 12)

    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post("/api/parameter-resets?data[type]=parameter-resets")
             |> json_response(400)

    assert unsaved(conn) == 1
    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.disparity.p1")
  end

  test "POST /api/parameter-resets answers 400 for relationships without a well-formed target, and resets nothing",
       %{conn: conn} do
    set("test.disparity.p1", 12)

    for relationships <- [
          %{target: %{type: "parameters", id: "test.disparity.p1"}},
          %{target: "test.disparity.p1"},
          %{},
          "target"
        ] do
      conn =
        post_document(conn, "/api/parameter-resets", %{
          type: "parameter-resets",
          relationships: relationships
        })

      assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => pointer}}]} =
               json_response(conn, 400)

      assert String.starts_with?(pointer, "/data/relationships")
    end

    assert parameter(conn, "test.disparity.p1")["attributes"]["value"] == 12
  end

  test "a reset carrying an id of the client's answers 403, and resets nothing", %{conn: conn} do
    set("test.disparity.p1", 12)

    conn = post_document(conn, "/api/parameter-resets", %{type: "parameter-resets", id: "mine"})

    assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
             json_response(conn, 403)

    assert unsaved(conn) == 1
    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.disparity.p1")
  end
end
