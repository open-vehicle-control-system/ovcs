defmodule OvcsBusGateway.Http.SignalsController do
  @moduledoc """
  JSON API over `OvcsBusGateway.Cache`; answers `{"error": "not_found"}` with a 404 for an
  unknown signal or route.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.{Cache, Http}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: json(conn, Cache.select(Http.filter(conn.query_params)))

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"node" => node, "source" => source, "name" => name}) do
    case Cache.fetch({node, source, name}) do
      {:ok, envelope} -> json(conn, envelope)
      :error -> not_found(conn, %{})
    end
  end

  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_status(404)
    |> json(%{error: "not_found"})
  end
end
