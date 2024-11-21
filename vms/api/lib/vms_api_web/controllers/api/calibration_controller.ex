defmodule VmsApiWeb.Api.CalibrationController do
  use VmsApiWeb, :controller

  def create(conn, params) do
    module = params["module"] |> String.to_existing_atom
    type   = params["type"]
    :ok = module.calibrate(type)

    conn
    |> put_status(:created)
    |> text("")
  end
end
