defmodule OvcsBusGateway.Http.NodesController do
  @moduledoc """
  The `nodes` resources, `OvcsBusGateway.Nodes` following JSON:API
  (`OvcsBusGateway.Http.Json.node/1`): each node's `name`, `connected`, `signalCount`,
  `staleCount` and `lastChangeAt`, related to its `signals`, in `included` with
  `include=signals`. Any other include or query parameter answers a 400, an unknown node a 404.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.{Cache, Nodes}
  alias OvcsBusGateway.Http.{Json, JsonApi}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with {:ok, include?} <- include_signals?(conn) do
      nodes = Nodes.list(Cache.select(%{}))
      json(conn, document(Enum.map(nodes, &Json.node/1), nodes, include?))
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, include?} <- include_signals?(conn) do
      case Nodes.list(Cache.select(%{node: id})) do
        [node] -> json(conn, document(Json.node(node), [node], include?))
        [] -> JsonApi.error(conn, 404, "Not Found", "no node #{id}")
      end
    end
  end

  defp document(data, _nodes, false), do: %{data: data}

  defp document(data, nodes, true) do
    %{data: data, included: for(node <- nodes, signal <- node.signals, do: Json.signal(signal))}
  end

  defp include_signals?(conn) do
    with :ok <- JsonApi.check_parameters(conn, ["include"]) do
      case conn.query_params["include"] do
        nil ->
          {:ok, false}

        "signals" ->
          {:ok, true}

        _other ->
          JsonApi.error(conn, 400, "Bad Request", "unsupported include", %{parameter: "include"})
      end
    end
  end
end
