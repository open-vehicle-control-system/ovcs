defmodule VmsApiWeb.Api.CarControlsSettingsController do
  use VmsApiWeb, :controller

  def create(conn, %{"interval" => _} = params) do
    :ok = VmsCore.Controllers.ControlsController.set_interval(params["interval"])
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{}")
  end
end
