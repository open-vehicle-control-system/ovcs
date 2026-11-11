defmodule VisionApiWeb.BoardControllerTest do
  use VisionApiWeb.ConnCase, async: true

  alias VisionApiWeb.BoardJSON

  test "GET /api/board answers the interfaces, the load and the clock, without synchronization on a host",
       %{conn: conn} do
    conn = get(conn, "/api/board")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "boards",
               "id" => "current",
               "attributes" => %{
                 "interfaces" => interfaces,
                 "cpuPercent" => cpu_percent,
                 "loadAverage" => [_, _, _],
                 "time" => time,
                 "clockSynchronized" => nil
               }
             }
           } = json_response(conn, 200)

    assert is_list(interfaces)
    assert is_number(cpu_percent)
    assert {:ok, _time, 0} = DateTime.from_iso8601(time)
  end

  test "a board carries its interfaces' addresses, its load, and its clock's time and synchronization" do
    board = %OvcsVehicle.BoardStatus{
      interfaces: [%{name: "eth0", addresses: ["192.168.10.232"]}],
      cpu_percent: 23.4,
      load_average: [0.52, 0.48, 0.4],
      time: ~U[2026-11-11 14:53:12Z],
      synchronized: false
    }

    assert BoardJSON.show(%{board: board}) == %{
             data: %{
               type: "boards",
               id: "current",
               attributes: %{
                 interfaces: [%{name: "eth0", addresses: ["192.168.10.232"]}],
                 cpuPercent: 23.4,
                 loadAverage: [0.52, 0.48, 0.4],
                 time: "2026-11-11T14:53:12Z",
                 clockSynchronized: false
               }
             }
           }
  end
end
