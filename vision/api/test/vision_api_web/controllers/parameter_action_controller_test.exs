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
    set("test.match.p1", 12)
    assert unsaved(conn) == 1

    conn = post_action(conn, "/api/parameter-saves", %{type: "parameter-saves"})
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "parameter-saves",
               "id" => id,
               "attributes" => %{"parameters" => ["test.match.p1"]}
             }
           } = json_response(conn, 201)

    assert is_binary(id)
    assert unsaved(conn) == 0
  end

  test "POST /api/parameter-saves answers 503 when the values cannot be stored", %{conn: conn} do
    :sys.replace_state(VisionCore.Parameters, &%{&1 | store: VisionApiWeb.FailingStore})
    set("test.match.p1", 12)

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
    set("test.match.p1", 12)

    conn = post_action(conn, "/api/parameter-discards", %{type: "parameter-discards"})

    assert %{
             "data" => %{
               "type" => "parameter-discards",
               "attributes" => %{"parameters" => ["test.match.p1"]}
             }
           } = json_response(conn, 201)

    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.match.p1")
  end

  test "POST /api/parameter-resets resets a parameter, a group, or everything without a target",
       %{conn: conn} do
    set("test.match.p1", 12)
    set("test.match.p2", 70)

    assert %{"data" => %{"type" => "parameter-resets", "attributes" => %{"parameters" => ids}}} =
             conn
             |> post_action("/api/parameter-resets", target("parameters", "test.match.p1"))
             |> json_response(201)

    assert ids == ["test.match.p1"]
    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.match.p1")

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.match.p2"]}}} =
             conn
             |> post_action("/api/parameter-resets", target("parameter-groups", "test.match"))
             |> json_response(201)

    set("test.match.p1", 12)

    assert %{"data" => %{"attributes" => %{"parameters" => ["test.match.p1"]}}} =
             conn
             |> post_action("/api/parameter-resets", %{type: "parameter-resets"})
             |> json_response(201)
  end

  test "POST /api/parameter-resets answers 404 for an unknown target", %{conn: conn} do
    for {type, id} <- [{"parameters", "nope"}, {"parameter-groups", "nope"}] do
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
          placement: :side,
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

    assert %{"status" => "422", "detail" => "test.stubborn.level: " <> _} = error
    refute Map.has_key?(error, "source")

    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post_action("/api/parameter-resets", target("widgets", "x"))
             |> json_response(400)
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

  test "GET /api/parameter-export answers the snippet", %{conn: conn} do
    conn = get(conn, "/api/parameter-export")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "parameter-exports",
               "id" => "current",
               "attributes" => %{"snippet" => snippet}
             }
           } = json_response(conn, 200)

    assert snippet =~ "# Nothing saved."
  end
end
