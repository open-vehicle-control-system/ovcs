defmodule OvcsBusGateway.Http.ConfigurationController do
  @moduledoc """
  The gateway's configuration, read-only: the `configurations` singleton `current`
  (`OvcsBusGateway.Http.Json.configuration/1`). A query parameter answers a 400.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.Settings
  alias OvcsBusGateway.Http.{Json, JsonApi}

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :ok <- JsonApi.check_parameters(conn, []) do
      json(conn, %{data: Json.configuration(Settings.get())})
    end
  end
end
