defmodule VisionApiWeb.ParameterActionControllerTest do
  use VisionApiWeb.ParametersCase

  defp post_action(conn, path, data) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, Jason.encode!(%{data: data}))
  end

  defp set(id, value), do: {:ok, _} = VisionCore.Parameters.set(id, value)

  defp unsaved(conn) do
    conn |> get("/api/parameters") |> json_response(200) |> get_in(["meta", "unsaved"])
  end

  defp target(type, id),
    do: %{type: "parameter-resets", relationships: %{target: %{data: %{type: type, id: id}}}}

  test "POST /api/parameter-saves saves and lists what it saved", %{conn: conn} do
    set("test.disparity.p1", 12)
    assert unsaved(conn) == 1

    conn = post_action(conn, "/api/parameter-saves", %{type: "parameter-saves"})
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "parameter-saves",
               "id" => id,
               "attributes" => %{"parameters" => ["test.disparity.p1"]}
             }
           } = json_response(conn, 201)

    assert is_binary(id)
    assert unsaved(conn) == 0
  end

  test "POST /api/parameter-saves answers 503 when the values cannot be stored", %{conn: conn} do
    :sys.replace_state(VisionCore.Parameters, &%{&1 | store: VisionApiWeb.FailingStore})
    set("test.disparity.p1", 12)

    conn = post_action(conn, "/api/parameter-saves", %{type: "parameter-saves"})

    assert %{
             "errors" => [
               %{
                 "status" => "503",
                 "title" => "Saved values unavailable",
                 "detail" => "saved parameters unavailable"
               }
             ]
           } = json_response(conn, 503)

    assert unsaved(conn) == 1
  end

  test "POST /api/parameter-discards puts unsaved changes back", %{conn: conn} do
    set("test.disparity.p1", 12)

    conn = post_action(conn, "/api/parameter-discards", %{type: "parameter-discards"})

    assert %{
             "data" => %{
               "type" => "parameter-discards",
               "attributes" => %{"parameters" => ["test.disparity.p1"]}
             }
           } = json_response(conn, 201)

    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.disparity.p1")
  end

  test "POST /api/parameter-resets resets a parameter, a stage, or everything without a target",
       %{conn: conn} do
    set("test.disparity.p1", 12)
    set("test.disparity.p2", 70)

    assert %{"data" => %{"type" => "parameter-resets", "attributes" => %{"parameters" => ids}}} =
             conn
             |> post_action("/api/parameter-resets", target("parameters", "test.disparity.p1"))
             |> json_response(201)

    assert ids == ["test.disparity.p1"]
    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.disparity.p1")

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.disparity.p2"]}}} =
             conn
             |> post_action("/api/parameter-resets", target("stages", "test.disparity"))
             |> json_response(201)

    set("test.disparity.p1", 12)

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.disparity.p1"]}}} =
             conn
             |> post_action("/api/parameter-resets", %{type: "parameter-resets"})
             |> json_response(201)
  end

  test "POST /api/parameter-resets answers 404 for an unknown target", %{conn: conn} do
    for {type, id} <- [{"parameters", "nope"}, {"stages", "nope"}] do
      assert %{"errors" => [%{"status" => "404"}]} =
               conn
               |> post_action("/api/parameter-resets", target(type, id))
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
             |> post_action("/api/parameter-resets", target("parameters", "test.stubborn.level"))
             |> json_response(422)

    assert %{"status" => "422", "title" => "Not reset", "detail" => "test.stubborn.level: " <> _} =
             error

    refute Map.has_key?(error, "source")

    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post_action("/api/parameter-resets", target("widgets", "x"))
             |> json_response(400)
  end

  test "an action sent as a form or in the query string, as another site's page can, is refused",
       %{conn: conn} do
    set("test.disparity.p1", 12)

    for {content_type, path, body} <- [
          {"application/x-www-form-urlencoded", "/api/parameter-saves",
           "data[type]=parameter-saves"},
          {"text/plain", "/api/parameter-saves", ~s({"data":{"type":"parameter-saves"}})},
          {nil, "/api/parameter-resets?data[type]=parameter-resets", nil}
        ] do
      conn = if content_type, do: put_req_header(conn, "content-type", content_type), else: conn

      assert %{"errors" => [%{"status" => "400"}]} =
               conn |> post(path, body) |> json_response(400)
    end

    assert unsaved(conn) == 1
    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.disparity.p1")
  end

  test "an action with the wrong type answers 409, without data 400", %{conn: conn} do
    assert %{"errors" => [%{"status" => "409"}]} =
             conn
             |> post_action("/api/parameter-saves", %{type: "parameter-discards"})
             |> json_response(409)

    assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data"}}]} =
             conn
             |> put_req_header("content-type", "application/vnd.api+json")
             |> post("/api/parameter-saves", "{}")
             |> json_response(400)
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
        post_action(conn, "/api/parameter-resets", %{
          type: "parameter-resets",
          relationships: relationships
        })

      assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => pointer}}]} =
               json_response(conn, 400)

      assert String.starts_with?(pointer, "/data/relationships")
    end

    assert parameter(conn, "test.disparity.p1")["attributes"]["value"] == 12
  end

  test "an action carrying an id of the client's answers 403, and does nothing", %{conn: conn} do
    set("test.disparity.p1", 12)

    for type <- ["parameter-saves", "parameter-discards", "parameter-resets"] do
      conn = post_action(conn, "/api/" <> type, %{type: type, id: "mine"})

      assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
               json_response(conn, 403)
    end

    assert unsaved(conn) == 1
    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.disparity.p1")
  end
end
