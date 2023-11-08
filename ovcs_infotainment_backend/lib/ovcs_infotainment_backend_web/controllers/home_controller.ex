defmodule OvcsInfotainmentBackendWeb.HomeController do
  use OvcsInfotainmentBackendWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, "priv/static/index.html")
  end

  defp filepath(file) do
    Path.expand("../../../priv/static/#{file}", Path.dirname(__ENV__.file))
  end
end
