defmodule InfotainmentApiWeb.Api.GearSelectorController do
  use InfotainmentApiWeb, :controller

  alias InfotainmentCore.VehicleStatus

  def post(conn, params) do
    {:ok, gear} = VehicleStatus.request_gear(params["gear"])
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{\"status\":\"ok\", \"gear\": \"#{gear}\"}")
  end
end
