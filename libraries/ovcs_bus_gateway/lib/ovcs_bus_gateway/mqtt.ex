defmodule OvcsBusGateway.Mqtt do
  @moduledoc """
  MQTT adapter: publishes every envelope, retained, as JSON.

  Topics are `ovcs/<vehicle>/<node>/<source>/<name>`, published at QoS 0. The process owns
  the `Tortoise311` connection to the broker. `Tortoise311` retries an unreachable broker on its own; when the
  connection process itself exits, this process traps the exit and starts a new one after
  the reconnect interval, so a broker fault never takes the gateway's supervision tree
  down. A lost connection is logged once as a warning, then at debug level until it is up
  again.

  The connection's last will publishes `false`, retained, on `ovcs/<vehicle>/gateway/online`.
  Each time the connection comes up, the gateway publishes `true` there, then every
  envelope in `OvcsBusGateway.Cache`, so the broker's retained values cover every signal,
  including those that do not change.

  Publishing is bounded: while the connection is not up, envelopes are dropped; a socket
  send that has not completed within a second closes the socket; and a batch that arrives
  with more than the queue limit of messages waiting is dropped. The cache republish on the
  next connection restores the retained values.

  Options:

  - `:vehicle` - vehicle module; `<vehicle>` is `OvcsBusGateway.vehicle_id/1` of it.
  - `:client_id` - MQTT client id.
  - `:host` - broker host.
  - `:port` - broker port.
  - `:publish` - `(client_id, topic, payload, opts -> term())`, default `&Tortoise311.publish/4`.
  - `:connect` - `(client_id, host, port -> {:ok, pid} | {:error, term()})` starting a
    connection linked to the caller, default starts `Tortoise311.Connection`. The caller
    receives `{{Tortoise311, client_id}, :status, status}` messages and publishes only after `:up`.
  - `:reconnect_interval` - milliseconds before a new connection is started, default 5000.
  - `:max_queue` - the queue limit, default 1000.
  """

  use GenServer
  require Logger

  alias OvcsBusGateway.{Cache, Envelope, Subscribers}
  alias Tortoise311.Package.Publish

  @reconnect_interval 5_000
  @max_queue 1_000
  @socket_opts [nodelay: true, send_timeout: 1_000, send_timeout_close: true]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The MQTT topic `envelope` is published on."
  @spec topic(String.t(), Envelope.t()) :: String.t()
  def topic(vehicle_id, %Envelope{} = envelope),
    do: "ovcs/#{vehicle_id}/#{envelope.node}/#{envelope.source}/#{envelope.name}"

  @doc "The MQTT topic telling whether the gateway is connected to the broker."
  @spec online_topic(String.t()) :: String.t()
  def online_topic(vehicle_id), do: "ovcs/#{vehicle_id}/gateway/online"

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    vehicle_id = OvcsBusGateway.vehicle_id(Keyword.fetch!(opts, :vehicle))
    online_topic = online_topic(vehicle_id)
    Subscribers.subscribe()
    send(self(), :connect)

    {:ok,
     %{
       vehicle_id: vehicle_id,
       client_id: Keyword.fetch!(opts, :client_id),
       online_topic: online_topic,
       host: Keyword.fetch!(opts, :host),
       port: Keyword.fetch!(opts, :port),
       publish: Keyword.get(opts, :publish, &Tortoise311.publish/4),
       connect: Keyword.get(opts, :connect, &connect(&1, &2, &3, online_topic)),
       reconnect_interval: Keyword.get(opts, :reconnect_interval, @reconnect_interval),
       max_queue: Keyword.get(opts, :max_queue, @max_queue),
       connection: nil,
       up?: false,
       warned?: false
     }}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case state.connect.(state.client_id, state.host, state.port) do
      {:ok, pid} -> {:noreply, %{state | connection: pid}}
      {:error, reason} -> {:noreply, schedule_reconnect(state, reason)}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{connection: pid} = state),
    do: {:noreply, schedule_reconnect(%{state | connection: nil, up?: false}, reason)}

  def handle_info({{Tortoise311, client_id}, :status, :up}, %{client_id: client_id} = state) do
    unless state.up? do
      publish(state.online_topic, "true", state)
      Enum.each(Cache.select(%{}), &publish_envelope(&1, state))
    end

    {:noreply, %{state | up?: true, warned?: false}}
  end

  def handle_info({{Tortoise311, client_id}, :status, status}, %{client_id: client_id} = state) do
    state = if state.up?, do: log_lost(state, status), else: state
    {:noreply, %{state | up?: false}}
  end

  def handle_info({:ovcs_bus_gateway, envelopes}, %{up?: true} = state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len > state.max_queue,
      do: Logger.debug("MQTT publisher falling behind, dropped #{length(envelopes)} envelopes"),
      else: Enum.each(envelopes, &publish_envelope(&1, state))

    {:noreply, state}
  end

  def handle_info({:ovcs_bus_gateway, _envelopes}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp connect(client_id, host, port, online_topic) do
    Tortoise311.Events.unregister(client_id, :status)

    with {:ok, _owner} <- Tortoise311.Events.register(client_id, :status) do
      Tortoise311.Connection.start_link(
        client_id: client_id,
        server: {Tortoise311.Transport.Tcp, host: host, port: port, opts: @socket_opts},
        handler: {OvcsBusGateway.Mqtt.Handler, []},
        will: %Publish{topic: online_topic, payload: "false", qos: 0, retain: true}
      )
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp schedule_reconnect(state, reason) do
    Process.send_after(self(), :connect, state.reconnect_interval)
    log_lost(state, reason)
  end

  defp log_lost(state, reason) do
    level = if state.warned?, do: :debug, else: :warning
    Logger.log(level, "MQTT connection to #{state.host}:#{state.port} down: #{inspect(reason)}")
    %{state | warned?: true}
  end

  defp publish_envelope(envelope, state) do
    publish(topic(state.vehicle_id, envelope), Jason.encode!(envelope), state)
  rescue
    error -> Logger.debug("MQTT envelope not encodable: #{Exception.message(error)}")
  end

  defp publish(topic, payload, state) do
    case state.publish.(state.client_id, topic, payload, qos: 0, retain: true, timeout: 0) do
      {:error, reason} -> Logger.debug("MQTT publish to #{topic} failed: #{inspect(reason)}")
      _ok -> :ok
    end
  rescue
    error -> Logger.debug("MQTT publish raised: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.debug("MQTT publish #{kind}: #{inspect(reason)}")
  end
end
