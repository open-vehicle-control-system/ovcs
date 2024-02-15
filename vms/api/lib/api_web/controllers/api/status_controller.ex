defmodule VmsApiWeb.Api.StatusController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    key_status = VmsCore.Vehicle.key_status()
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{\"status\":\"ok\", \"keyStatus\": \"#{key_status}\"}")
  end
end
