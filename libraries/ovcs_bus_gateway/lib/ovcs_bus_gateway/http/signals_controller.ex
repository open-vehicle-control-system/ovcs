defmodule OvcsBusGateway.Http.SignalsController do
  @moduledoc """
  The `signals` resources over `OvcsBusGateway.Cache`, following JSON:API. A signal's id is
  `<node>/<source>/<name>` and its attributes are its envelope's JSON,
  `OvcsBusGateway.Envelope.to_json/1`.

  `index` takes `filter[node]`, `filter[source]` and `filter[name]`, an empty one matching
  everything, and answers a 400 naming any other query parameter; `show` answers a 404 for an
  unknown signal.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.{Cache, Envelope}
  alias OvcsBusGateway.Http.JsonApi

  @filters %{"node" => :node, "source" => :source, "name" => :name}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case filter(conn.query_params) do
      {:ok, filter} ->
        json(conn, %{data: Enum.map(Cache.select(filter), &resource/1)})

      {:error, parameter} ->
        detail = "unsupported query parameter #{parameter}"
        JsonApi.error(conn, 400, "Bad Request", detail, %{parameter: parameter})
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"node" => node, "source" => source, "name" => name}) do
    case Cache.fetch({node, source, name}) do
      {:ok, envelope} -> json(conn, %{data: resource(envelope)})
      :error -> JsonApi.error(conn, 404, "Not Found", "no signal #{id({node, source, name})}")
    end
  end

  defp resource(envelope) do
    JsonApi.resource("signals", id(Envelope.key(envelope)), Envelope.to_json(envelope))
  end

  defp id({node, source, name}), do: Enum.join([node, source, name], "/")

  defp filter(params) do
    case Map.pop(params, "filter", %{}) do
      {filters, rest} when rest != %{} and is_map(filters) ->
        {:error, rest |> Map.keys() |> Enum.min()}

      {filters, _rest} when is_map(filters) ->
        filter_fields(filters)

      {_filters, _rest} ->
        {:error, "filter"}
    end
  end

  defp filter_fields(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn
      {key, ""}, acc when is_map_key(@filters, key) ->
        {:cont, acc}

      {key, value}, {:ok, filter} when is_map_key(@filters, key) and is_binary(value) ->
        {:cont, {:ok, Map.put(filter, @filters[key], value)}}

      {key, _value}, _acc ->
        {:halt, {:error, "filter[#{key}]"}}
    end)
  end
end
