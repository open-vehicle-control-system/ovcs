defmodule VisionApiWeb.DashboardController do
  @moduledoc "Serves the dashboard's `index.html` for every path the API does not handle."
  use VisionApiWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, Path.join(:code.priv_dir(:vision_api), "static/index.html"))
  end
end
