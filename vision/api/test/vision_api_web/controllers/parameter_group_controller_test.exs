defmodule VisionApiWeb.ParameterGroupControllerTest do
  use VisionApiWeb.ParametersCase

  test "GET /api/parameter-groups lists groups as JSON:API resources with their parameters included",
       %{conn: conn} do
    conn = get(conn, "/api/parameter-groups?include=parameters")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"data" => groups, "included" => included, "meta" => %{"unsaved" => 0}} =
             json_response(conn, 200)

    group = Enum.find(groups, &(&1["id"] == "test.match"))

    assert %{
             "type" => "parameter-groups",
             "id" => "test.match",
             "attributes" => %{
               "name" => "Match",
               "kind" => "stage",
               "placement" => "flow",
               "position" => 2,
               "status" => %{"level" => "ok", "detail" => "fine"}
             },
             "relationships" => %{
               "parameters" => %{
                 "data" => [%{"type" => "parameters", "id" => "test.match.p1"} | _]
               }
             }
           } = group

    assert Enum.any?(included, &(&1["id"] == "test.match.p1"))
  end

  test "the index actions read each parameter once and count the unsaved ones they answer",
       %{conn: conn} do
    reads = start_supervised!({Agent, fn -> 0 end}, id: :reads)

    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.flicker",
          name: "Flicker",
          summary: "Reads differently each time.",
          kind: :component,
          placement: :side,
          position: 8,
          parameters: [
            %{
              name: "level",
              type: :integer,
              default: 0,
              get: fn -> Agent.get_and_update(reads, &{rem(&1, 2), &1 + 1}) end,
              set: fn _value -> :ok end
            }
          ]
        }
      ])

    for path <- ["/api/parameters", "/api/parameter-groups?include=parameters"] do
      _ = :sys.get_state(VisionCore.Parameters)
      before = Agent.get(reads, & &1)
      document = json_response(get(conn, path), 200)
      assert Agent.get(reads, & &1) == before + 1

      unsaved =
        Enum.count(
          document["data"] ++ Map.get(document, "included", []),
          &(&1["type"] == "parameters" and &1["attributes"]["state"] == "unsaved")
        )

      assert document["meta"]["unsaved"] == unsaved
    end
  end

  test "GET /api/parameter-groups leaves the parameters out unless included", %{conn: conn} do
    assert %{"data" => [_ | _]} = body = json_response(get(conn, "/api/parameter-groups"), 200)
    refute Map.has_key?(body, "included")
  end

  test "GET /api/parameter-groups answers 400 for an include it does not support", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
             json_response(get(conn, "/api/parameter-groups?include=nope"), 400)
  end
end
