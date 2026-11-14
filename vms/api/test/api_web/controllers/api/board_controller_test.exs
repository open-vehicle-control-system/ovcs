defmodule VmsApiWeb.Api.BoardControllerTest do
  # The suite runs with `--no-start`, so the controller is called directly.
  use VmsApiWeb.ConnCase, async: true

  alias OvcsVehicle.BoardStatus
  alias VmsApiWeb.Api.BoardController

  test "answers the shared board document, without synchronization on a host", %{conn: conn} do
    conn = BoardController.call(conn, :show)
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    %{"data" => data} = document = json_response(conn, 200)
    %{"data" => shared_data} = shared = shared_document()

    assert Map.keys(document) == Map.keys(shared)
    assert Map.keys(data) == Map.keys(shared_data)
    assert {data["type"], data["id"]} == {shared_data["type"], shared_data["id"]}
    assert Map.keys(data["attributes"]) == Map.keys(shared_data["attributes"])

    assert %{
             "interfaces" => interfaces,
             "cpuPercent" => cpu_percent,
             "loadAverage" => [_, _, _],
             "memoryPercent" => memory_percent,
             "time" => time,
             "clockSynchronized" => nil
           } = data["attributes"]

    assert is_list(interfaces)
    assert is_number(cpu_percent)
    assert is_number(memory_percent)
    assert {:ok, _time, 0} = DateTime.from_iso8601(time)
  end

  defp shared_document do
    %BoardStatus{
      interfaces: [],
      cpu_percent: nil,
      load_average: nil,
      memory_percent: nil,
      time: ~U[2026-11-11 14:53:12Z],
      synchronized: nil
    }
    |> BoardStatus.document()
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
