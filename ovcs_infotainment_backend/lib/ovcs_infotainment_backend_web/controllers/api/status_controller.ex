defmodule OvcsInfotainmentBackendWeb.Api.StatusController do
  use OvcsInfotainmentBackendWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{'status':'ok'}")
  end
end
