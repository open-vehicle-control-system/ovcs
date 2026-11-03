defmodule OvcsBusGateway.Http.NotFoundController do
  @moduledoc "Answers API paths the router does not know with a JSON:API 404, whatever the client accepts."

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.Http.JsonApi

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    JsonApi.error(conn, 404, "Not Found", "no route for #{conn.method} #{conn.request_path}")
  end
end
