defmodule VisionApiWeb.NotFoundController do
  @moduledoc "Answers API paths the router does not know with a JSON 404."
  use VisionApiWeb, :controller

  def show(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(json: VisionApiWeb.ErrorJSON)
    |> render(:"404")
  end
end
