defmodule VmsApiWeb.Api.VehicleJSONTest do
  use ExUnit.Case, async: true

  alias VmsApiWeb.Api.VehicleJSON

  test "a vehicle carries its name and refresh interval only" do
    assert %{attributes: attributes} =
             VehicleJSON.render("vehicle.json", %{
               vehicle: %{name: "My Car", refresh_interval: 100}
             })

    assert attributes == %{name: "My Car", refreshInterval: 100}
  end
end
