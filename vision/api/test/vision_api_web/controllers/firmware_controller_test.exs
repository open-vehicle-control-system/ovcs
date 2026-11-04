defmodule VisionApiWeb.FirmwareControllerTest do
  use VisionApiWeb.ConnCase, async: false

  alias VisionApiWeb.FirmwareJSON

  setup do
    Application.put_env(:ovcs_vehicle, :firmware, revision: "ce99e251", target: "host")
    on_exit(fn -> Application.delete_env(:ovcs_vehicle, :firmware) end)
  end

  test "GET /api/firmware answers the commit and the target, without a Nerves system on a host",
       %{conn: conn} do
    conn = get(conn, "/api/firmware")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert json_response(conn, 200) == %{
             "data" => %{
               "type" => "firmwares",
               "id" => "current",
               "attributes" => %{
                 "revision" => "ce99e251",
                 "target" => "host",
                 "nervesSystem" => nil,
                 "nervesSystemVersion" => nil,
                 "vehicle" => nil
               }
             }
           }
  end

  test "a board's firmware names its Nerves system and its vehicle" do
    firmware = %OvcsVehicle.FirmwareInfo{
      revision: "ce99e251",
      target: "okdo_c100",
      nerves_system: "nerves_system_okdo_c100",
      nerves_system_version: "0.3.0",
      vehicle: "OVCS Mini"
    }

    assert %{
             data: %{
               attributes: %{
                 nervesSystem: "nerves_system_okdo_c100",
                 nervesSystemVersion: "0.3.0",
                 vehicle: "OVCS Mini"
               }
             }
           } =
             FirmwareJSON.show(%{firmware: firmware})
  end
end
