defmodule OvcsBus.Mqtt.Relay do
  @moduledoc """
  Mirrors selected `OvcsBus.Message` names to/from an MQTT broker
  via `Tortoise311`. One instance per firmware; connect every
  firmware in a vehicle to the same broker to build a vehicle-wide
  bus on top of each firmware's local `Phoenix.PubSub`.

  Tortoise311 is a pure-Elixir MQTT 3.1.1 client — no native
  dependencies — so this module cross-compiles on any Nerves target.

  ## Usage

      children = [
        {OvcsBus.Mqtt.Relay,
         broker: [host: "ovcs1-vms.local", port: 1884],
         client_id: "ovcs1-ros-bridge",
         topic_prefix: "ovcs/ovcs1/bus",
         topics: [:ready_to_drive, :gear_selected, :speed],
         topic: "messages"}
      ]

  ## Opts

    * `:broker`       — keyword list / map with `:host` (string),
                        `:port` (int, default `1884`), optional
                        `:user_name`, `:password`, `:keep_alive`.
    * `:client_id`    — MQTT client id; auto-generated if omitted.
                        Must be unique per firmware instance.
    * `:topic_prefix` — broker topic root; each bus message name
                        `X` maps to `<topic_prefix>/<X>`.
    * `:topics`       — atom (or string) names to mirror.
    * `:topic`        — local `OvcsBus` topic the relay subscribes to.
                        Defaults to `"messages"`.

  ## Echo avoidance

  Inbound payloads are decoded into `%OvcsBus.Message{relay_origin:
  :mqtt}`; the outbound side ignores any message whose
  `:relay_origin` is non-nil, so a message received via MQTT isn't
  republished back to the broker.
  """
  use GenServer
  require Logger

  @default_topic "messages"
  @default_port 1884

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = normalize(opts)
    topic = Keyword.get(opts, :topic, @default_topic)
    topic_prefix = Keyword.fetch!(opts, :topic_prefix)
    broker = opts |> Keyword.fetch!(:broker) |> normalize()
    client_id = Keyword.get(opts, :client_id, client_id_fallback())
    names = opts |> Keyword.fetch!(:topics) |> Enum.map(&to_string/1)

    subscriptions =
      Enum.map(names, fn name -> {"#{topic_prefix}/#{name}", 0} end)

    conn_opts = [
      client_id: client_id,
      server: tortoise_server(broker),
      handler: {OvcsBus.Mqtt.Relay.Handler, [bus_topic: topic]},
      subscriptions: subscriptions
    ]

    conn_opts = maybe_put(conn_opts, :user_name, broker[:user_name])
    conn_opts = maybe_put(conn_opts, :password, broker[:password])
    conn_opts = maybe_put(conn_opts, :keep_alive, broker[:keep_alive])

    {:ok, _pid} = Tortoise311.Connection.start_link(conn_opts)

    :ok = OvcsBus.subscribe(topic)

    {:ok,
     %{
       client_id: client_id,
       topic: topic,
       topic_prefix: topic_prefix,
       name_index: MapSet.new(names)
     }}
  end

  # Locally published — forward to broker unless it's an echo of
  # something we just relayed inbound.
  @impl true
  def handle_info(
        %OvcsBus.Message{relay_origin: nil, name: name} = message,
        %{client_id: client_id, topic_prefix: prefix, name_index: names} = state
      ) do
    name_str = to_string(name)

    if MapSet.member?(names, name_str) do
      payload = :erlang.term_to_binary(message)
      _ = Tortoise311.publish(client_id, "#{prefix}/#{name_str}", payload, qos: 0)
    end

    {:noreply, state}
  end

  def handle_info(%OvcsBus.Message{}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp tortoise_server(broker) do
    host = broker |> Keyword.fetch!(:host) |> to_charlist()
    port = Keyword.get(broker, :port, @default_port)
    {Tortoise311.Transport.Tcp, host: host, port: port}
  end

  defp client_id_fallback do
    node = :erlang.node() |> to_string()
    "ovcs-bus-relay-#{node}-#{System.unique_integer([:positive])}"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize(%{} = opts), do: Enum.to_list(opts)
  defp normalize(opts) when is_list(opts), do: opts
end

defmodule OvcsBus.Mqtt.Relay.Handler do
  @moduledoc false
  use Tortoise311.Handler
  require Logger

  @impl true
  def init(opts), do: {:ok, %{bus_topic: Keyword.fetch!(opts, :bus_topic)}}

  @impl true
  def connection(_status, state), do: {:ok, state}

  @impl true
  def handle_message(_topic, payload, state) do
    case decode(payload) do
      {:ok, %OvcsBus.Message{} = msg} ->
        tagged = %{msg | relay_origin: :mqtt}
        OvcsBus.broadcast(state.bus_topic, tagged)

      {:ok, other} ->
        # Any other term published to a mirrored topic: drop silently so
        # a misconfigured producer can't crash the handler (and, through
        # Tortoise311, tear the connection down).
        Logger.warning("OvcsBus.Mqtt.Relay: drop non-Message term: #{inspect(other)}")

      {:error, reason} ->
        Logger.warning("OvcsBus.Mqtt.Relay: drop payload: #{inspect(reason)}")
    end

    {:ok, state}
  end

  @impl true
  def subscription(_status, _topic_filter, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # Producers on each side of the bus publish fields as atoms (gear
  # states, control modes, status keys, etc.) that the peer hasn't
  # necessarily materialised yet. `:safe` rejects any such atom and
  # the whole message gets dropped — so we decode without it. Safe on
  # a closed vehicle LAN with only OVCS producers; revisit if the
  # broker is ever exposed.
  defp decode(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    _ -> {:error, :bad_payload}
  end
end
