defmodule VmsApiWeb.Api.Vehicle.Page.BlocksJSONTest do
  use ExUnit.Case, async: true

  alias VmsApiWeb.Api.Vehicle.Page.BlocksJSON

  @y_axis %{min: 0, max: 100, label: "%", series: [%{name: "Throttle"}]}

  test "a y-axis forwards its position" do
    assert %{position: "right"} =
             BlocksJSON.render("y_axis.json", %{y_axis: Map.put(@y_axis, :position, "right")})
  end

  test "a y-axis without a position sends none" do
    refute Map.has_key?(BlocksJSON.render("y_axis.json", %{y_axis: @y_axis}), :position)
  end
end
