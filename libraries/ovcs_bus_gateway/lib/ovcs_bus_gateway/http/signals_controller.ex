defmodule OvcsBusGateway.Http.SignalsController do
  @moduledoc """
  The `signals` resources over `OvcsBusGateway.Cache`, following JSON:API (`OvcsBusGateway.Http.Json.signal/1`):
  every signal of the bus except the nodes' presence, which `OvcsBusGateway.Http.NodesController`
  serves as each node's `connected`.

  `index` takes `filter[node]`, `filter[source]` and `filter[name]`, an empty one matching
  everything, and answers a 400 naming any other query parameter; `show` answers a 404 for an
  unknown signal.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.{Cache, Collector}
  alias OvcsBusGateway.Http.{Json, JsonApi}

  @filters %{"node" => :node, "source" => :source, "name" => :name}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case filter(conn.query_params) do
      {:ok, filter} ->
        signals = filter |> Cache.select() |> Enum.reject(&Collector.presence?/1)
        json(conn, %{data: Enum.map(signals, &Json.signal/1)})

      {:error, parameter} ->
        JsonApi.unsupported_parameter(conn, parameter)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"node" => node, "source" => source, "name" => name}) do
    with :ok <- JsonApi.check_parameters(conn, []),
         {:ok, envelope} <- fetch_signal({node, source, name}) do
      json(conn, %{data: Json.signal(envelope)})
    else
      :error -> JsonApi.error(conn, 404, "Not Found", "no signal #{node}/#{source}/#{name}")
      %Plug.Conn{} = refused -> refused
    end
  end

  defp fetch_signal(key) do
    case Cache.fetch(key) do
      {:ok, envelope} -> if Collector.presence?(envelope), do: :error, else: {:ok, envelope}
      :error -> :error
    end
  end

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
