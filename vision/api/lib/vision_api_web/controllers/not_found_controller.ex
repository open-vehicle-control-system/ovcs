defmodule VisionApiWeb.NotFoundController do
  @moduledoc """
  Answers the API requests the router has no route for, whatever the
  client accepts: a JSON:API 405 naming in `allow` the methods the path
  takes, or a 404 for a path that takes none.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi

  @methods ~w(GET POST PATCH PUT DELETE)

  def show(conn, _params) do
    case allowed(conn) do
      [] ->
        JsonApi.error(conn, 404, "no route for #{conn.method} #{conn.request_path}")

      methods ->
        allow = Enum.join(methods, ", ")

        conn
        |> put_resp_header("allow", allow)
        |> JsonApi.error(405, "#{conn.request_path} takes #{allow}")
    end
  end

  defp allowed(conn) do
    for method <- @methods,
        %{plug: plug} <- [route(conn, method)],
        plug != __MODULE__,
        do: method
  end

  defp route(conn, method),
    do: Phoenix.Router.route_info(VisionApiWeb.Router, method, conn.request_path, conn.host)
end
