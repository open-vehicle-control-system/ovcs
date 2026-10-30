defmodule VisionApiWeb.ParameterGroupControllerTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm) do
      %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", node_name: "vision_test", components: []}
    end
  end

  setup do
    Application.stop(:vision_core)
    Application.put_env(:vision_core, :vehicle, Composer)
    {:ok, _apps} = Application.ensure_all_started(:vision_core)

    on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.ensure_all_started(:vision_core)
    end)

    values = start_supervised!({Agent, fn -> %{p1: 8, p2: 64, exposure: 100, auto: true} end})
    get = fn key -> fn -> Agent.get(values, & &1[key]) end end
    set = fn key -> fn value -> Agent.update(values, &Map.put(&1, key, value)) end end

    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.match",
          name: "Match",
          summary: "Matches.",
          kind: :stage,
          placement: :flow,
          position: 2,
          status: fn -> {:ok, "fine"} end,
          parameters: [
            %{
              name: "p1",
              type: :integer,
              get: get.(:p1),
              set: set.(:p1),
              constraint: %{kind: :range, min: 0, max: 78, step: nil}
            },
            %{
              name: "p2",
              type: :integer,
              get: get.(:p2),
              set: set.(:p2),
              greater_than: "p1"
            },
            %{name: "width", type: :integer, get: fn -> 480 end, applies: :build},
            %{
              name: "exposure",
              type: :integer,
              get: get.(:exposure),
              set: set.(:exposure),
              applies: {:auto, "test.match.auto"}
            },
            %{
              name: "auto",
              type: :bool,
              get: get.(:auto),
              set: set.(:auto),
              constraint: %{kind: :bool}
            }
          ]
        }
      ])
  end

  defp parameter(conn, id) do
    conn |> get("/api/parameters/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "GET /api/parameter-groups lists groups as JSON:API resources with their parameters included",
       %{conn: conn} do
    conn = get(conn, "/api/parameter-groups?include=parameters")
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/vnd.api+json"

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

  test "GET /api/parameter-groups leaves the parameters out unless included", %{conn: conn} do
    assert %{"data" => [_ | _]} = body = json_response(get(conn, "/api/parameter-groups"), 200)
    refute Map.has_key?(body, "included")
  end

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
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/vnd.api+json"

    assert %{"errors" => [%{"status" => "404", "title" => "Not Found"}]} =
             json_response(conn, 404)
  end
end
