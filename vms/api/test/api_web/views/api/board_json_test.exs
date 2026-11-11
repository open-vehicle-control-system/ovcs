defmodule VmsApiWeb.Api.BoardJSONTest do
  use ExUnit.Case, async: true

  alias VmsApiWeb.Api.BoardJSON

  test "the board carries its interfaces' addresses and its clock's time and synchronization" do
    board = %OvcsVehicle.BoardStatus{
      interfaces: [%{name: "eth0", addresses: ["192.168.1.20"]}],
      time: ~U[2026-11-11 14:53:12Z],
      synchronized: true
    }

    assert BoardJSON.render("show.json", %{board: board}) == %{
             data: %{
               type: "board",
               id: "current",
               attributes: %{
                 interfaces: [%{name: "eth0", addresses: ["192.168.1.20"]}],
                 time: "2026-11-11T14:53:12Z",
                 clockSynchronized: true
               }
             }
           }
  end
end
