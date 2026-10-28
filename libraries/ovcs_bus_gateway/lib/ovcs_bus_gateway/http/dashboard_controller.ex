defmodule OvcsBusGateway.Http.DashboardController do
  @moduledoc """
  Serves the bus dashboard's `index.html` from the `:static_dir` app env, by default
  `priv/static`, or a 404 that says how to build it.
  """

  use Phoenix.Controller, formats: [:html]

  @not_built "Bus dashboard not built: run npm run build in libraries/ovcs_bus_gateway/dashboard"

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    index = Path.join(static_dir(), "index.html")

    if File.regular?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index)
    else
      send_resp(conn, 404, @not_built)
    end
  end

  defp static_dir do
    Application.get_env(:ovcs_bus_gateway, :static_dir) ||
      Path.join(:code.priv_dir(:ovcs_bus_gateway), "static")
  end
end
