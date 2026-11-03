defmodule OvcsBusGateway.Http.Json do
  @moduledoc """
  The gateway's resources as JSON, keys in camelCase: the JSON:API resource objects of `/api`,
  and the plain objects the `status` channel pushes.
  """

  alias OvcsBusGateway.{Adapters, Envelope, Nodes, Settings}
  alias OvcsBusGateway.Http.JsonApi

  @doc "A signal's id, `<node>/<source>/<name>`, which is also its path under `/api/signals`."
  @spec signal_id(Envelope.t()) :: String.t()
  def signal_id(envelope), do: envelope |> Envelope.key() |> Tuple.to_list() |> Enum.join("/")

  @doc "The `signals` resource of `envelope`, related to its node."
  @spec signal(Envelope.t()) :: map()
  def signal(envelope) do
    JsonApi.resource("signals", signal_id(envelope), Envelope.to_json(envelope), %{
      node: JsonApi.to_one("nodes", envelope.node)
    })
  end

  @doc "The `nodes` resource of `node`, related to its signals."
  @spec node(Nodes.t()) :: map()
  def node(%Nodes{} = node) do
    attributes = Map.put(node_attributes(node), :lastChangeAt, Nodes.last_change_at(node))

    JsonApi.resource("nodes", node.id, attributes, %{
      signals: JsonApi.to_many("signals", Enum.map(node.signals, &signal_id/1))
    })
  end

  @doc "`node` as the `status` channel pushes it."
  @spec node_status(Nodes.t()) :: map()
  def node_status(%Nodes{} = node), do: Map.put(node_attributes(node), :id, node.id)

  @doc "The `adapters` resource of `adapter`."
  @spec adapter(Adapters.t()) :: map()
  def adapter(adapter), do: JsonApi.resource("adapters", adapter.id, adapter_attributes(adapter))

  @doc "`adapter` as the `status` channel pushes it."
  @spec adapter_status(Adapters.t()) :: map()
  def adapter_status(adapter), do: Map.put(adapter_attributes(adapter), "id", adapter.id)

  @doc """
  The `configurations` resource `current`: the vehicle, the MQTT client id, and `config`, keyed
  by `OvcsBusGateway.Config`'s field names.
  """
  @spec configuration(Settings.t()) :: map()
  def configuration(%Settings{config: config} = settings) do
    JsonApi.resource("configurations", "current", %{
      vehicle: inspect(settings.vehicle),
      mqttClientId: settings.mqtt_client_id,
      config: %{
        mqtt: options(config.mqtt),
        http: options(config.http),
        forward_interval: config.forward_interval
      }
    })
  end

  defp node_attributes(node) do
    %{
      name: node.id,
      connected: node.connected,
      signalCount: length(node.signals),
      staleCount: Nodes.stale_count(node)
    }
  end

  defp adapter_attributes(adapter) do
    adapter
    |> Map.delete(:id)
    |> Map.update!(:module, &inspect/1)
    |> Map.new(fn {key, value} -> {camel_case(key), value} end)
  end

  defp camel_case(key) do
    [first | rest] = key |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  defp options(nil), do: nil
  defp options(options), do: Map.new(options)
end
