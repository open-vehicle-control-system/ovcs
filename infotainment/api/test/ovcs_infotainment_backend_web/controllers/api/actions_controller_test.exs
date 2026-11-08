defmodule InfotainmentApiWeb.Api.ActionsControllerTest do
  # The suite runs with `--no-start`, so the controller is called
  # directly rather than through the endpoint. The composer is global
  # application env, hence not async.
  use InfotainmentApiWeb.ConnCase, async: false

  alias InfotainmentApiWeb.Api.ActionsController

  defmodule Component do
    def trigger_action("succeed", _params), do: :ok
    def trigger_action("refuse", _params), do: {:error, :not_parked}
    def trigger_action("undeclared", _params), do: raise("an undeclared action ran")
  end

  defmodule NoTriggerAction do
  end

  defmodule Composer do
    alias InfotainmentApiWeb.Api.ActionsControllerTest.{Component, NoTriggerAction}

    def infotainment_configuration do
      %{
        vehicle: %{
          pages: %{
            "drive" => %{
              blocks: %{
                "gear" => %{
                  type: "gearSelector",
                  metrics: [%{module: Component, key: :selected_gear}],
                  actions: [
                    %{module: Component, action: "succeed"},
                    %{module: Component, action: "refuse"},
                    %{module: NoTriggerAction, action: "succeed"}
                  ]
                },
                "clock" => %{type: "clock"}
              }
            }
          }
        }
      }
    end
  end

  setup do
    previous_composer = Application.get_env(:infotainment_core, :vehicle)
    Application.put_env(:infotainment_core, :vehicle, Composer)

    on_exit(fn ->
      if previous_composer,
        do: Application.put_env(:infotainment_core, :vehicle, previous_composer),
        else: Application.delete_env(:infotainment_core, :vehicle)
    end)
  end

  defp create(conn, params) do
    conn
    |> Phoenix.Controller.put_format("json")
    |> ActionsController.create(params)
  end

  defp create(conn, module_name, action) do
    create(conn, %{"module" => module_name, "action" => action})
  end

  test "an action the component performs answers 201", %{conn: conn} do
    assert conn |> create(to_string(Component), "succeed") |> response(201) == ""
  end

  test "an action the component refuses answers 422 with its reason", %{conn: conn} do
    assert conn |> create(to_string(Component), "refuse") |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Entity", "reason" => "not_parked"}
           }
  end

  test "an action the configuration does not declare answers 404", %{conn: conn} do
    assert conn |> create(to_string(Component), "undeclared") |> json_response(404) == %{
             "errors" => %{"detail" => "Not Found"}
           }
  end

  test "a module the configuration does not declare answers 404", %{conn: conn} do
    assert conn |> create("Elixir.System", "succeed") |> response(404)
  end

  test "a declared module without trigger_action/2 answers 404", %{conn: conn} do
    assert conn |> create(to_string(NoTriggerAction), "succeed") |> response(404)
  end

  test "an unknown module answers 404 without creating its atom", %{conn: conn} do
    module_name = "Elixir.NeverDefined#{System.unique_integer([:positive])}"

    assert conn |> create(module_name, "succeed") |> response(404)
    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "a request without module or action answers 404", %{conn: conn} do
    assert conn |> create(%{"action" => "succeed"}) |> response(404)
    assert conn |> create(%{"module" => to_string(Component)}) |> response(404)
  end
end
