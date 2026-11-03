defmodule OvcsBusGateway.Http.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias OvcsBusGateway.{Cache, Config, Envelope, Settings, Subscribers}
  alias OvcsBusGateway.Http.Router

  @media_type "application/vnd.api+json"

  setup do
    start_supervised!(Cache)
    start_supervised!(Subscribers)

    start_supervised!(
      {Settings,
       %Settings{
         vehicle: OvcsMini,
         config: %Config{mqtt: nil, http: [port: 4100]},
         mqtt_client_id: "ovcs_bus_gateway_ovcs_mini"
       }}
    )

    Cache.put_all([
      %Envelope{
        node: "vms",
        source: "OvcsBusGateway.Collector",
        name: "connected",
        value: true,
        changed_at: 0,
        published_at: 0
      },
      %Envelope{
        node: "vms",
        source: "VmsCore.Vehicle",
        name: "speed",
        value: 3,
        unit: "km/h",
        changed_at: 0,
        published_at: 5,
        stale: false
      },
      %Envelope{
        node: "ros",
        source: "Ros.Bridge",
        name: "yaw",
        value: 1,
        changed_at: 0,
        published_at: 5
      }
    ])

    :ok
  end

  defp request(method, path), do: Router.call(conn(method, path), Router.init([]))
  defp get(path), do: request(:get, path)
  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp ids(conn), do: conn |> body() |> Map.fetch!("data") |> Enum.map(& &1["id"]) |> Enum.sort()

  defp assert_media_type(conn) do
    assert Plug.Conn.get_resp_header(conn, "content-type") == [@media_type]
    conn
  end

  defp assert_error(conn, status, detail) do
    assert conn.status == status
    assert_media_type(conn)
    assert %{"errors" => [%{"status" => status_text, "detail" => ^detail} = error]} = body(conn)
    assert status_text == Integer.to_string(status)
    error
  end

  test "lists every signal as a JSON:API resource, without the nodes' presence" do
    conn = get("/api/signals")

    assert conn.status == 200
    assert_media_type(conn)
    assert ids(conn) == ["ros/Ros.Bridge/yaw", "vms/VmsCore.Vehicle/speed"]
  end

  test "gives a signal its envelope in camelCase as attributes" do
    assert %{"data" => [resource]} = body(get("/api/signals?filter[node]=vms"))

    assert resource == %{
             "type" => "signals",
             "id" => "vms/VmsCore.Vehicle/speed",
             "attributes" => %{
               "node" => "vms",
               "source" => "VmsCore.Vehicle",
               "name" => "speed",
               "value" => 3,
               "unit" => "km/h",
               "changedAt" => 0,
               "publishedAt" => 5,
               "stale" => false
             },
             "relationships" => %{"node" => %{"data" => %{"type" => "nodes", "id" => "vms"}}}
           }
  end

  test "filters by node, source and name, an empty filter matching everything" do
    assert ids(get("/api/signals?filter[source]=Ros.Bridge&filter[name]=yaw")) == [
             "ros/Ros.Bridge/yaw"
           ]

    assert ids(get("/api/signals?filter[node]=&filter[source]=&filter[name]=")) |> length() == 2
  end

  test "refuses another query parameter, naming it" do
    error = assert_error(get("/api/signals?node=vms"), 400, "unsupported query parameter node")
    assert error["source"] == %{"parameter" => "node"}

    error =
      assert_error(
        get("/api/signals?filter[unit]=V"),
        400,
        "unsupported query parameter filter[unit]"
      )

    assert error["source"] == %{"parameter" => "filter[unit]"}

    assert_error(get("/api/signals?filter=vms"), 400, "unsupported query parameter filter")

    assert_error(
      get("/api/signals?filter[node][]=vms"),
      400,
      "unsupported query parameter filter[node]"
    )
  end

  test "fetches one signal" do
    conn = get("/api/signals/vms/VmsCore.Vehicle/speed")

    assert conn.status == 200
    assert_media_type(conn)

    assert %{"data" => %{"id" => "vms/VmsCore.Vehicle/speed", "attributes" => %{"value" => 3}}} =
             body(conn)
  end

  test "answers a 404 naming an unknown signal" do
    assert_error(
      get("/api/signals/vms/VmsCore.Vehicle/missing"),
      404,
      "no signal vms/VmsCore.Vehicle/missing"
    )
  end

  test "answers a 404 naming an unknown API route, whatever the method" do
    assert_error(get("/api/frames"), 404, "no route for GET /api/frames")
    assert_error(request(:post, "/api/signals"), 404, "no route for POST /api/signals")
  end

  test "answers a 404 for a node's presence, which is not a signal" do
    assert_error(
      get("/api/signals/vms/OvcsBusGateway.Collector/connected"),
      404,
      "no signal vms/OvcsBusGateway.Collector/connected"
    )
  end

  test "lists the nodes, each with its presence and its signals" do
    conn = get("/api/nodes")

    assert conn.status == 200
    assert_media_type(conn)
    assert %{"data" => [ros, vms]} = body(conn)

    assert vms == %{
             "type" => "nodes",
             "id" => "vms",
             "attributes" => %{
               "name" => "vms",
               "connected" => true,
               "signalCount" => 1,
               "staleCount" => 0,
               "lastChangeAt" => 0
             },
             "relationships" => %{
               "signals" => %{
                 "data" => [%{"type" => "signals", "id" => "vms/VmsCore.Vehicle/speed"}]
               }
             }
           }

    assert ros["attributes"]["connected"] == nil
    refute Map.has_key?(body(conn), "included")
  end

  test "includes the nodes' signals on request" do
    assert %{"data" => %{"id" => "vms"}, "included" => [%{"type" => "signals", "id" => id}]} =
             body(get("/api/nodes/vms?include=signals"))

    assert id == "vms/VmsCore.Vehicle/speed"

    error = assert_error(get("/api/nodes?include=adapters"), 400, "unsupported include")
    assert error["source"] == %{"parameter" => "include"}
  end

  test "answers a 404 naming an unknown node" do
    assert_error(get("/api/nodes/infotainment"), 404, "no node infotainment")
  end

  test "lists the adapters with their status" do
    assert %{"data" => [mqtt, http]} = body(get("/api/adapters"))

    assert mqtt == %{
             "type" => "adapters",
             "id" => "mqtt",
             "attributes" => %{
               "name" => "MQTT",
               "module" => "OvcsBusGateway.Mqtt",
               "status" => %{"level" => "off", "detail" => "No broker in the configuration"}
             }
           }

    assert %{"id" => "http", "attributes" => %{"port" => 4100, "clients" => 0}} = http
  end

  test "describes the configuration, keyed by the config's field names" do
    assert body(get("/api/configuration")) == %{
             "data" => %{
               "type" => "configurations",
               "id" => "current",
               "attributes" => %{
                 "vehicle" => "OvcsMini",
                 "mqttClientId" => "ovcs_bus_gateway_ovcs_mini",
                 "config" => %{
                   "mqtt" => nil,
                   "http" => %{"port" => 4100},
                   "forward_interval" => 20
                 }
               }
             }
           }
  end

  test "refuses a query parameter a route does not take" do
    assert_error(get("/api/adapters?sort=name"), 400, "unsupported query parameter sort")
    assert_error(get("/api/configuration?include=x"), 400, "unsupported query parameter include")
  end

  @tag :tmp_dir
  test "explains how to build the dashboard when it is absent", %{tmp_dir: dir} do
    Application.put_env(:ovcs_bus_gateway, :static_dir, dir)
    on_exit(fn -> Application.delete_env(:ovcs_bus_gateway, :static_dir) end)

    conn = get("/")

    assert conn.status == 404

    assert conn.resp_body ==
             "Bus dashboard not built: run npm run build in libraries/ovcs_bus_gateway/dashboard"
  end

  @tag :tmp_dir
  test "serves the dashboard on any other path", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "<html>bus</html>")
    Application.put_env(:ovcs_bus_gateway, :static_dir, dir)
    on_exit(fn -> Application.delete_env(:ovcs_bus_gateway, :static_dir) end)

    for path <- ["/", "/nodes/vms"] do
      conn = get(path)

      assert conn.status == 200
      assert conn.resp_body == "<html>bus</html>"
    end
  end
end
