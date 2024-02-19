defmodule InfotainmentApiWeb.HomeController do
  use InfotainmentApiWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, filepath("static/index.html"))
  end

  defp filepath(file) do
    Path.join(:code.priv_dir(:infotainment_api), file)
  end
end
