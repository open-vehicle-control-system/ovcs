defmodule VisionApiWeb.BoardControllerTest do
  use VisionApiWeb.ConnCase, async: true

  alias VisionApiWeb.BoardJSON

  test "GET /api/board answers the interfaces and the clock, without synchronization on a host",
       %{conn: conn} do
    conn = get(conn, "/api/board")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "boards",
               "id" => "current",
               "attributes" => %{
                 "interfaces" => interfaces,
                 "time" => time,
                 "clockSynchronized" => nil
               }
             }
           } = json_response(conn, 200)

    assert is_list(interfaces)
    assert {:ok, _time, 0} = DateTime.from_iso8601(time)
  end

  test "a board's interfaces carry their addresses, and its clock its time and synchronization" do
    board = %OvcsVehicle.BoardStatus{
      interfaces: [%{name: "eth0", addresses: ["192.168.10.232"]}],
      time: ~U[2026-11-11 14:53:12Z],
      synchronized: false
    }

    assert BoardJSON.show(%{board: board}) == %{
             data: %{
               type: "boards",
               id: "current",
               attributes: %{
                 interfaces: [%{name: "eth0", addresses: ["192.168.10.232"]}],
                 time: "2026-11-11T14:53:12Z",
                 clockSynchronized: false
               }
             }
           }
  end
end
