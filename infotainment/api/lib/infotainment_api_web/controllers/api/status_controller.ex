defmodule InfotainmentApiWeb.Api.StatusController do
  use InfotainmentApiWeb, :controller

  alias InfotainmentCore.Status

  def show(conn, _params) do
    {:ok, overview} = Status.car_overview()
    {:ok, overview_json} = JSON.encode(overview)
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, overview_json)
  end
end
