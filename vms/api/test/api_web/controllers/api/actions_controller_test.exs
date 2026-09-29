defmodule VmsApiWeb.Api.ActionsControllerTest do
  # The suite runs with `--no-start`, so the controller is called
  # directly rather than through the endpoint.
  use VmsApiWeb.ConnCase, async: true

  alias VmsApiWeb.Api.ActionsController

  defmodule Component do
    def trigger_action("succeed", _params), do: :ok
    def trigger_action("refuse", _params), do: {:error, :not_calibrating}
  end

  defp create(conn, action) do
    conn
    |> Phoenix.Controller.put_format("json")
    |> ActionsController.create(%{"module" => to_string(Component), "action" => action})
  end

  test "an action the component performs answers 201", %{conn: conn} do
    assert conn |> create("succeed") |> response(201) == ""
  end

  test "an action the component refuses answers 422 with its reason", %{conn: conn} do
    assert conn |> create("refuse") |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Entity", "reason" => "not_calibrating"}
           }
  end
end
