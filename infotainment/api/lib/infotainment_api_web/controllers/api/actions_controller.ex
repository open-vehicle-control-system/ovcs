defmodule InfotainmentApiWeb.Api.ActionsController do
  use InfotainmentApiWeb, :controller

  def create(conn, params) do
    module = params["module"] |> String.to_existing_atom
    action = params["action"]
    :ok    = module.trigger_action(action, params)

    conn
    |> put_status(:created)
    |> text("")
  end
end
