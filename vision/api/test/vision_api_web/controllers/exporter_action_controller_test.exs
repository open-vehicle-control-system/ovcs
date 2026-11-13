defmodule VisionApiWeb.ExporterActionControllerTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

  # Answers each action with the result its name says.
  defmodule Acting do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(_options), do: %{id: :acting, name: "Acting"}

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}

    @impl VisionCore.Exporter
    def actions(_options),
      do:
        for(
          name <- ~w(export echo occupied stalled broken)a,
          do: %{name: name, label: "Run #{name}", description: "Runs #{name}."}
        )

    @impl VisionCore.Exporter
    def handle_action(:export, _params, _from, state),
      do: {:reply, {:file, "export.zip", "application/zip", "PK fake zip"}, state}

    def handle_action(:echo, params, _from, state), do: {:reply, {:ok, params}, state}
    def handle_action(:occupied, _params, _from, state), do: {:reply, {:error, :busy}, state}

    def handle_action(:stalled, _params, _from, state),
      do: {:reply, {:error, {:timeout, "The export took longer than 30 s"}}, state}

    def handle_action(:broken, _params, _from, state),
      do: {:reply, {:error, {:failed, "No frames arrived"}}, state}
  end

  setup do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{exporters: [Acting]})
  end

  defp run_action(conn, path, document \\ %{data: %{type: "exporter-actions"}}) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, Jason.encode!(document))
  end

  test "answers a file result as a download", %{conn: conn} do
    conn = run_action(conn, "/api/exporters/acting/actions/export")

    assert response(conn, 200) == "PK fake zip"
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert [~s(attachment; filename="export.zip")] = get_resp_header(conn, "content-disposition")
  end

  test "answers a JSON result as an exporter-actions document, handing over the attributes",
       %{conn: conn} do
    document = %{data: %{type: "exporter-actions", attributes: %{"burst" => 30}}}
    conn = run_action(conn, "/api/exporters/acting/actions/echo", document)

    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "exporter-actions",
               "id" => id,
               "attributes" => %{"burst" => 30}
             }
           } = json_response(conn, 200)

    assert is_binary(id)
  end

  test "an action given no attributes receives none", %{conn: conn} do
    assert %{"data" => %{"attributes" => attributes}} =
             conn |> run_action("/api/exporters/acting/actions/echo") |> json_response(200)

    assert attributes == %{}
  end

  test "refuses attributes that are no object with a 400", %{conn: conn} do
    document = %{data: %{type: "exporter-actions", attributes: [30]}}

    assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data/attributes"}}]} =
             conn
             |> run_action("/api/exporters/acting/actions/echo", document)
             |> json_response(400)
  end

  test "an action sent as a form or in the query string, as another site's page can, is refused",
       %{conn: conn} do
    for {content_type, path, body} <- [
          {"application/x-www-form-urlencoded", "/api/exporters/acting/actions/echo",
           "data[type]=exporter-actions"},
          {"text/plain", "/api/exporters/acting/actions/echo",
           ~s({"data":{"type":"exporter-actions"}})},
          {nil, "/api/exporters/acting/actions/echo?data[type]=exporter-actions", nil}
        ] do
      conn = if content_type, do: put_req_header(conn, "content-type", content_type), else: conn

      assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data"}}]} =
               conn |> post(path, body) |> json_response(400)
    end
  end

  test "answers 400 for a body without a document", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> put_req_header("content-type", "application/vnd.api+json")
             |> post("/api/exporters/acting/actions/export", "{}")
             |> json_response(400)
  end

  test "answers 409 for another data.type", %{conn: conn} do
    assert %{"errors" => [%{"status" => "409", "source" => %{"pointer" => "/data/type"}}]} =
             conn
             |> run_action("/api/exporters/acting/actions/export", %{data: %{type: "parameters"}})
             |> json_response(409)
  end

  test "answers 403 for a document carrying an id of the client's", %{conn: conn} do
    assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
             conn
             |> run_action("/api/exporters/acting/actions/export", %{
               data: %{type: "exporter-actions", id: "mine"}
             })
             |> json_response(403)
  end

  test "answers 404 for an unknown exporter, the API's own entry among them", %{conn: conn} do
    for id <- ["nothing", "api"] do
      assert %{"errors" => [%{"status" => "404", "detail" => "no exporter " <> ^id}]} =
               conn |> run_action("/api/exporters/#{id}/actions/export") |> json_response(404)
    end
  end

  test "answers 404 for an action the exporter does not list, without creating an atom from it",
       %{conn: conn} do
    name = "no-such-action-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
             conn |> run_action("/api/exporters/acting/actions/#{name}") |> json_response(404)

    assert detail == "exporter acting has no action #{name}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "answers 409 when the exporter is busy", %{conn: conn} do
    assert %{"errors" => [%{"status" => "409", "title" => "Busy", "detail" => detail}]} =
             conn |> run_action("/api/exporters/acting/actions/occupied") |> json_response(409)

    assert detail =~ "acting"
  end

  test "answers 503 when the exporter is not running", %{conn: conn} do
    :ok = Supervisor.terminate_child(VisionCore.Exporters, :acting)

    assert %{"errors" => [%{"status" => "503", "detail" => detail}]} =
             conn |> run_action("/api/exporters/acting/actions/export") |> json_response(503)

    assert detail =~ "acting"
  end

  test "answers 504 with the timeout's message", %{conn: conn} do
    assert %{"errors" => [%{"status" => "504", "detail" => "The export took longer than 30 s"}]} =
             conn |> run_action("/api/exporters/acting/actions/stalled") |> json_response(504)
  end

  test "answers 500 with the failure's message", %{conn: conn} do
    assert %{"errors" => [%{"status" => "500", "detail" => "No frames arrived"}]} =
             conn |> run_action("/api/exporters/acting/actions/broken") |> json_response(500)
  end

  test "GET /api/exporters lists each exporter's actions", %{conn: conn} do
    assert %{"data" => [acting, api]} = conn |> get("/api/exporters") |> json_response(200)

    assert %{"id" => "acting", "attributes" => %{"actions" => actions}} = acting

    assert Enum.map(actions, & &1["name"]) == ~w(export echo occupied stalled broken)

    assert %{"name" => "export", "label" => "Run export", "description" => "Runs export."} =
             hd(actions)

    assert %{"id" => "api", "attributes" => %{"actions" => []}} = api
  end
end
