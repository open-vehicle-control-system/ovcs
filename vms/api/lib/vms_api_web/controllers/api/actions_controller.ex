defmodule VmsApiWeb.Api.ActionsController do
  use VmsApiWeb, :controller

  def create(conn, params) do
    module = params["module"] |> String.to_existing_atom()
    action = params["action"]

    case module.trigger_action(action, params) do
      :ok ->
        conn
        |> put_status(:created)
        |> text("")

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: VmsApiWeb.ErrorJSON)
        |> render(:"422", reason: reason)
    end
  end
end
