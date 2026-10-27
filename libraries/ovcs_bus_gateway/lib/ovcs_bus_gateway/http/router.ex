defmodule OvcsBusGateway.Http.Router do
  @moduledoc """
  Routes of `OvcsBusGateway.Http`.
  """

  use Plug.Router

  alias OvcsBusGateway.Cache
  alias OvcsBusGateway.Http.Socket

  @not_built "Bus dashboard not built: run npm run build in libraries/ovcs_bus_gateway/dashboard"

  plug Plug.Static,
    at: "/",
    from: {:ovcs_bus_gateway, "priv/static"},
    only: ~w(assets favicon.ico)

  plug :match
  plug :fetch_query_params
  plug :dispatch

  get "/api/signals" do
    json(conn, 200, Cache.select(filter(conn.query_params)))
  end

  get "/api/signals/:node/:source/:name" do
    case Cache.fetch({node, source, name}) do
      {:ok, envelope} -> json(conn, 200, envelope)
      :error -> not_found(conn)
    end
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Socket, filter(conn.query_params), [])
    |> halt()
  end

  get "/" do
    index = Path.join(static_dir(), "index.html")

    if File.regular?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index)
    else
      send_resp(conn, 404, @not_built)
    end
  end

  match _ do
    not_found(conn)
  end

  @doc """
  Builds an `t:OvcsBusGateway.filter/0` from the `node`, `source` and `name` query params
  that are present and non-empty.
  """
  @spec filter(map()) :: OvcsBusGateway.filter()
  def filter(params) do
    for key <- ~w(node source name),
        value = params[key],
        is_binary(value) and value != "",
        into: %{},
        do: {String.to_existing_atom(key), value}
  end

  defp static_dir do
    Application.get_env(:ovcs_bus_gateway, :static_dir) ||
      Path.join(:code.priv_dir(:ovcs_bus_gateway), "static")
  end

  defp not_found(conn), do: json(conn, 404, %{error: "not_found"})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
