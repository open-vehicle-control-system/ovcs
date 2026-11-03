defmodule OvcsBusGateway.Http.AdaptersController do
  @moduledoc """
  The `adapters` resources, `OvcsBusGateway.Adapters` following JSON:API: MQTT, then HTTP, each
  with its `status` (`level` and `detail`). A query parameter answers a 400.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.Adapters
  alias OvcsBusGateway.Http.{Json, JsonApi}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with :ok <- JsonApi.check_parameters(conn, []) do
      json(conn, %{data: Enum.map(Adapters.list(), &Json.adapter/1)})
    end
  end
end
