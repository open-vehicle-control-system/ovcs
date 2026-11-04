defmodule VmsApiWeb.Api.FirmwareJSONTest do
  use ExUnit.Case, async: true

  alias VmsApiWeb.Api.FirmwareJSON

  test "the firmware carries its commit, target, Nerves system and vehicle" do
    firmware = %OvcsVehicle.FirmwareInfo{
      revision: "ce99e251",
      target: "rpi4",
      nerves_system: "nerves_system_rpi4",
      nerves_system_version: "1.30.0",
      vehicle: "OVCS1"
    }

    assert FirmwareJSON.render("show.json", %{firmware: firmware}) == %{
             data: %{
               type: "firmware",
               id: "current",
               attributes: %{
                 revision: "ce99e251",
                 target: "rpi4",
                 nervesSystem: "nerves_system_rpi4",
                 nervesSystemVersion: "1.30.0",
                 vehicle: "OVCS1"
               }
             }
           }
  end
end
