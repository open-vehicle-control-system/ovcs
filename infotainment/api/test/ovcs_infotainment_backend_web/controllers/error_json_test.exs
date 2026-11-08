defmodule InfotainmentApiWeb.ErrorJSONTest do
  use InfotainmentApiWeb.ConnCase, async: true

  test "renders 404" do
    assert InfotainmentApiWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert InfotainmentApiWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "renders 422 with the refusal's reason" do
    assert InfotainmentApiWeb.ErrorJSON.render("422.json", %{reason: "not parked"}) ==
             %{errors: %{detail: "Unprocessable Entity", reason: "not parked"}}

    assert InfotainmentApiWeb.ErrorJSON.render("422.json", %{reason: {:bad, 1}}) ==
             %{errors: %{detail: "Unprocessable Entity", reason: "{:bad, 1}"}}
  end
end
