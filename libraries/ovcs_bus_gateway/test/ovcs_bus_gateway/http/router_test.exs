defmodule OvcsBusGateway.Http.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias OvcsBusGateway.{Cache, Envelope}
  alias OvcsBusGateway.Http.Router

  setup do
    start_supervised!(Cache)

    Cache.put_all([
      %Envelope{node: "vms", source: "VmsCore.Vehicle", name: "speed", value: 3, timestamp: 0},
      %Envelope{node: "ros", source: "Ros.Bridge", name: "yaw", value: 1, timestamp: 0}
    ])

    :ok
  end

  defp get(path), do: Router.call(conn(:get, path), Router.init([]))

  test "lists signals filtered by node" do
    conn = get("/api/signals?node=vms")

    assert conn.status == 200
    assert [%{"node" => "vms"}] = Jason.decode!(conn.resp_body)
  end

  test "lists every signal without a filter" do
    assert [_, _] = Jason.decode!(get("/api/signals").resp_body)
  end

  test "ignores empty filter params" do
    assert [_, _] = Jason.decode!(get("/api/signals?node=&source=&name=").resp_body)
  end

  test "fetches one signal" do
    conn = get("/api/signals/vms/VmsCore.Vehicle/speed")

    assert conn.status == 200
    assert %{"value" => 3} = Jason.decode!(conn.resp_body)
  end

  test "404 on an unknown signal" do
    conn = get("/api/signals/vms/VmsCore.Vehicle/missing")

    assert conn.status == 404
    assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
  end

  test "404 on an unknown route" do
    conn = get("/nope")

    assert conn.status == 404
    assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
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
  test "serves index.html when the dashboard is built", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "<html>bus</html>")
    Application.put_env(:ovcs_bus_gateway, :static_dir, dir)
    on_exit(fn -> Application.delete_env(:ovcs_bus_gateway, :static_dir) end)

    conn = get("/")

    assert conn.status == 200
    assert conn.resp_body == "<html>bus</html>"
  end
end
