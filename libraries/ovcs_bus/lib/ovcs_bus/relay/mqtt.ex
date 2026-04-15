defmodule OvcsBus.Relay.Mqtt do
  @moduledoc """
  Mirrors selected `OvcsBus.Message` names to/from an MQTT broker via
  `:emqtt`. One instance per firmware; connect all firmwares in a
  vehicle to the same broker to build a vehicle-wide bus on top of
  each firmware's local `Phoenix.PubSub`.

  ## Usage

      children = [
        {OvcsBus.Relay.Mqtt,
         broker: [host: "ovcs1-vms.local", port: 1884],
         client_id: "ovcs1-ros-bridge",
         topic_prefix: "ovcs/ovcs1/bus",
         topics: [:ready_to_drive, :gear_selected, :speed],
         topic: "messages"}
      ]

  - `:broker` — emqtt connection options (host, port, username, password, …).
  - `:client_id` — MQTT client id; defaults to `vehicle-side` on
    startup if omitted.
  - `:topic_prefix` — broker topic root; each bus message name `X`
    maps to `<topic_prefix>/<X>`.
  - `:topics` — atom names (or string names) to mirror in both
    directions.
  - `:topic` — local `OvcsBus` topic the relay subscribes to. Defaults
    to `"messages"` (the convention used across OVCS firmwares).

  ## Echo avoidance

  Inbound MQTT payloads are decoded into `%OvcsBus.Message{relay_origin: :mqtt}`
  structs before being broadcast locally. The outbound path ignores any
  message whose `:relay_origin` is non-nil, so a message received via
  MQTT isn't republished back to the broker.
  """
  use GenServer
  require Logger

  @relay_key :mqtt
  @default_topic "messages"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    topic_prefix = Keyword.fetch!(opts, :topic_prefix)
    broker = Keyword.fetch!(opts, :broker)
    client_id = Keyword.get(opts, :client_id, client_id_fallback())

    names =
      opts
      |> Keyword.fetch!(:topics)
      |> Enum.map(&to_string/1)

    {:ok, pid} = :emqtt.start_link(broker_opts(broker, client_id))
    {:ok, _} = :emqtt.connect(pid)

    Enum.each(names, fn name ->
      {:ok, _, _} = :emqtt.subscribe(pid, {"#{topic_prefix}/#{name}", 0})
    end)

    :ok = OvcsBus.subscribe(topic)

    {:ok,
     %{
       client: pid,
       topic: topic,
       topic_prefix: topic_prefix,
       name_index: MapSet.new(names)
     }}
  end

  @impl true
  # Locally published — forward to broker unless it's an echo of
  # something we just relayed inbound.
  def handle_info(
        %OvcsBus.Message{relay_origin: nil, name: name} = message,
        %{client: pid, topic_prefix: prefix, name_index: names} = state
      ) do
    name_str = to_string(name)

    if MapSet.member?(names, name_str) do
      payload = :erlang.term_to_binary(message)
      :ok = :emqtt.publish(pid, "#{prefix}/#{name_str}", payload, qos: 0)
    end

    {:noreply, state}
  end

  def handle_info(%OvcsBus.Message{}, state), do: {:noreply, state}

  # Inbound from broker — decode + broadcast locally with relay_origin set.
  def handle_info({:publish, %{topic: mqtt_topic, payload: payload}}, %{topic: bus_topic} = state) do
    with {:ok, %OvcsBus.Message{} = msg} <- decode(payload) do
      tagged = %{msg | relay_origin: @relay_key}
      OvcsBus.broadcast(bus_topic, tagged)
    else
      {:error, reason} ->
        Logger.warning("OvcsBus.Relay.Mqtt: drop #{inspect(mqtt_topic)}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp broker_opts(broker, client_id) do
    broker
    |> Keyword.put_new(:clientid, client_id)
    |> Keyword.put_new(:clean_start, true)
  end

  defp client_id_fallback do
    node = :erlang.node() |> to_string()
    "ovcs-bus-relay-#{node}-#{System.unique_integer([:positive])}"
  end

  defp decode(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _ -> {:error, :bad_payload}
  end
end
