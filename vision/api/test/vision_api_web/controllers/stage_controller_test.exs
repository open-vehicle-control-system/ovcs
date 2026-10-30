defmodule VisionApiWeb.StageControllerTest do
  use VisionApiWeb.ParametersCase

  test "GET /api/stages lists stages as JSON:API resources with their parameters included",
       %{conn: conn} do
    conn = get(conn, "/api/stages?include=parameters")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"data" => stages, "included" => included, "meta" => %{"unsaved" => 0}} =
             json_response(conn, 200)

    stage = Enum.find(stages, &(&1["id"] == "test.disparity"))

    assert %{
             "type" => "stages",
             "id" => "test.disparity",
             "attributes" => %{
               "name" => "Disparity",
               "role" => "step",
               "position" => 2,
               "status" => %{"level" => "ok", "detail" => "fine"}
             },
             "relationships" => %{
               "parameters" => %{
                 "data" => [%{"type" => "parameters", "id" => "test.disparity.p1"} | _]
               }
             }
           } = stage

    assert Enum.any?(included, &(&1["id"] == "test.disparity.p1"))
  end

  test "a stage's role says where it sits: a source or step in the flow, a branch beside it",
       %{conn: conn} do
    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.camera",
          name: "Camera",
          summary: "Captures.",
          kind: :component,
          placement: :flow,
          position: 0,
          parameters: []
        },
        %{
          id: "test.filter",
          name: "Filter",
          summary: "Filters.",
          kind: :stage,
          placement: :flow,
          position: 1,
          parameters: []
        },
        %{
          id: "test.detector",
          name: "Detector",
          summary: "Detects.",
          kind: :component,
          placement: :side,
          position: 7,
          parameters: []
        }
      ])

    roles =
      for %{"id" => id, "attributes" => %{"role" => role}} <-
            json_response(get(conn, "/api/stages"), 200)["data"],
          into: %{},
          do: {id, role}

    assert roles == %{
             "test.camera" => "source",
             "test.filter" => "step",
             "test.detector" => "branch"
           }
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

    for path <- ["/api/parameters", "/api/stages?include=parameters"] do
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

  test "GET /api/stages leaves the parameters out unless included", %{conn: conn} do
    assert %{"data" => [_ | _]} = body = json_response(get(conn, "/api/stages"), 200)
    refute Map.has_key?(body, "included")
  end

  test "GET /api/stages answers 400 for an include it does not support", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
             json_response(get(conn, "/api/stages?include=nope"), 400)
  end
end
