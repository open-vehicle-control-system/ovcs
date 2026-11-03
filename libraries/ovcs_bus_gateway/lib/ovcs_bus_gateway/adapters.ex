defmodule OvcsBusGateway.Adapters do
  @moduledoc """
  The gateway's ways out, MQTT and HTTP, each with its status: `level` is `:ok` while it works,
  `:warning` when it is configured but not working, and `:off` when the configuration leaves it
  out; `detail` says which.

  Besides `id`, `name`, `module` and `status`, MQTT has its `broker`, `client_id` and `topic`
  layout, and HTTP its `port` and its `clients`, the `signals` channels joined.
  """

  alias OvcsBusGateway.{Mqtt, Settings, Subscribers}

  @type level :: :ok | :warning | :off
  @type t :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:module) => module(),
          required(:status) => %{level: level(), detail: String.t()},
          optional(atom()) => term()
        }

  @doc "MQTT, then HTTP."
  @spec list() :: [t()]
  def list do
    %Settings{config: config, mqtt_client_id: client_id} = Settings.get()
    [mqtt(config.mqtt, client_id), http(config.http)]
  end

  defp mqtt(nil, _client_id) do
    %{
      id: "mqtt",
      name: "MQTT",
      module: Mqtt,
      status: status(:off, "No broker in the configuration")
    }
  end

  defp mqtt(options, client_id) do
    broker = "#{options[:host]}:#{options[:port]}"

    status =
      case Mqtt.connection() do
        :up -> status(:ok, "Connected to #{broker}")
        :down -> status(:warning, "Not connected to #{broker}")
        :unknown -> status(:warning, "Not answering")
        nil -> status(:warning, "Not running")
      end

    %{
      id: "mqtt",
      name: "MQTT",
      module: Mqtt,
      status: status,
      broker: broker,
      client_id: client_id,
      topic: Mqtt.topic_layout()
    }
  end

  defp http(nil) do
    %{
      id: "http",
      name: "HTTP",
      module: OvcsBusGateway.Http,
      status: status(:off, "No port in the configuration")
    }
  end

  defp http(options) do
    port = Keyword.get(options, :port, OvcsBusGateway.Http.default_port())

    %{
      id: "http",
      name: "HTTP",
      module: OvcsBusGateway.Http,
      status: status(:ok, "Answering on port #{port}"),
      port: port,
      clients: Subscribers.count(:signals_channel)
    }
  end

  defp status(level, detail), do: %{level: level, detail: detail}
end
