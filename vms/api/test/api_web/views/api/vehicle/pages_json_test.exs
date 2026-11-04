defmodule VmsApiWeb.Api.Vehicle.PagesJSONTest do
  use ExUnit.Case, async: true

  alias VmsApiWeb.Api.Vehicle.PagesJSON

  test "a page carries its name only" do
    assert %{id: "status", attributes: attributes} =
             PagesJSON.render("page.json", %{page: {"status", %{name: "Status", order: 0}}})

    assert attributes == %{name: "Status"}
  end
end
