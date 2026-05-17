defmodule RosBridge.ZenohClient.State do
  defstruct [
    :endpoint_ip,
    :node_name,
    :topic,
    :msg_module,
    :domain_id,
    :key_expr,
    :gid,
    :interval_ms,
    :session,
    :publisher,
    :liveliness_token,
    :timer,
    counter: 0,
    # %{key_expr => %{topic, msg_module, pids, subscriber_id}}
    subscriptions: %{}
  ]
end

defmodule RosBridge.ZenohClient do
  @moduledoc """
  Native-Zenoh client (via `zenohex`) that publishes a heartbeat to
  the OVCS Zenoh fabric as a real ROS 2 `std_msgs/String` message and
  exposes a `subscribe/2` API for callers that want to consume ROS 2
  topics off the same session.

  Uses `Ros2.RmwZenoh` to build the rmw_zenoh keyexpr, CDR-wrap the
  payload, and attach the publisher metadata that subscribers (e.g.
  `foxglove_bridge`, `ros2 topic echo`) require.

  Subscribers are matched on the rmw_zenoh wildcard
  `<domain>/<topic>/**`, which is robust to type-hash drift across
  ROS 2 distros — the CDR payload is parsed by the caller-supplied
  message module.
  """
  use GenServer
  alias RosBridge.ZenohClient.State
  alias Ros2.RmwZenoh
  alias Ros2.StdMsgs.Msg.String, as: RosString
  require Logger

  @default_node_name "ovcs_bridge"
  @default_topic "ovcs_heartbeat"
  @default_msg_module RosString
  @default_domain_id 0
  @default_interval_ms 5_000
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 30_000
  @zenoh_port 7447

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe `pid` (defaults to caller) to a ROS 2 topic. Incoming
  samples are CDR-decoded with `msg_module.parse/1` and delivered as
  `{:ros_message, {key_expr, parsed_message}}`.

  Safe to call before the session is open; the subscription is
  declared on the next successful connect and re-declared after any
  reconnect.
  """
  def subscribe(topic, msg_module, pid \\ self(), opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, topic, msg_module, pid, opts})
  end

  @impl true
  def init(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    msg_module = Keyword.get(opts, :msg_module, @default_msg_module)
    domain_id = Keyword.get(opts, :domain_id, @default_domain_id)
    node_name = Keyword.get(opts, :node_name, @default_node_name)

    state = %State{
      endpoint_ip: Keyword.fetch!(opts, :endpoint_ip),
      node_name: node_name,
      topic: topic,
      msg_module: msg_module,
      domain_id: domain_id,
      # Stable per-process GID so consecutive samples look like they
      # come from the same publisher (rmw_zenoh subscribers track this
      # to dedupe / order). Generated on init and reused across
      # reconnects.
      gid: RmwZenoh.random_gid(),
      key_expr: RmwZenoh.key_expr(domain_id, topic, msg_module),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    send(self(), {:connect, @reconnect_initial_ms})
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, topic, msg_module, pid, _opts}, _from, state) do
    key_expr = subscription_key_expr(state.domain_id, topic)

    sub =
      Map.get(state.subscriptions, key_expr, %{
        topic: topic,
        msg_module: msg_module,
        pids: [],
        subscriber_id: nil
      })

    pids = if pid in sub.pids, do: sub.pids, else: [pid | sub.pids]
    sub = %{sub | pids: pids}

    sub =
      if state.session && is_nil(sub.subscriber_id) do
        case declare_subscriber(state.session, key_expr) do
          {:ok, id} ->
            Logger.info("#{__MODULE__} subscribed to #{key_expr}")
            %{sub | subscriber_id: id}

          {:error, reason} ->
            Logger.warning(
              "#{__MODULE__} declare_subscriber #{key_expr} failed: #{inspect(reason)}"
            )

            sub
        end
      else
        sub
      end

    {:reply, :ok, %{state | subscriptions: Map.put(state.subscriptions, key_expr, sub)}}
  end

  @impl true
  def handle_info({:connect, backoff_ms}, state) do
    with {:ok, session} <- open_session(state.endpoint_ip),
         {:ok, %Zenohex.Session.Info{zid: zid}} <- Zenohex.Session.info(session),
         {:ok, publisher} <- Zenohex.Session.declare_publisher(session, state.key_expr, []),
         liveliness_key <-
           Ros2.RmwZenoh.liveliness_key(
             state.domain_id,
             zid,
             state.node_name,
             state.topic,
             state.msg_module
           ),
         {:ok, token} <- Zenohex.Liveliness.declare_token(session, liveliness_key) do
      Logger.info(
        "#{__MODULE__} connected to tcp/#{state.endpoint_ip}:#{@zenoh_port}, " <>
          "zid=#{zid}, publishing #{inspect(state.msg_module)} on #{state.key_expr} " <>
          "every #{state.interval_ms}ms"
      )

      Logger.info("#{__MODULE__} declared liveliness token #{liveliness_key}")

      subscriptions = redeclare_subscribers(session, state.subscriptions)

      timer = Process.send_after(self(), :tick, state.interval_ms)

      {:noreply,
       %{
         state
         | session: session,
           publisher: publisher,
           liveliness_token: token,
           timer: timer,
           subscriptions: subscriptions
       }}
    else
      {:error, reason} ->
        schedule_reconnect(state, backoff_ms, "connect failed: #{inspect(reason)}")
    end
  end

  def handle_info(:tick, %State{publisher: publisher} = state) when not is_nil(publisher) do
    counter = state.counter + 1
    msg = build_message(state.msg_module, counter)
    payload = RmwZenoh.encode_payload(msg)
    attachment = RmwZenoh.attachment(counter, System.system_time(:nanosecond), state.gid)

    case Zenohex.Publisher.put(publisher, payload, attachment: attachment) do
      :ok ->
        Logger.info(
          "#{__MODULE__} put ##{counter} on #{state.key_expr} " <>
            "(#{byte_size(payload)}B payload + #{byte_size(attachment)}B attachment): " <>
            inspect(msg)
        )

        timer = Process.send_after(self(), :tick, state.interval_ms)
        {:noreply, %{state | counter: counter, timer: timer}}

      {:error, reason} ->
        Logger.warning("#{__MODULE__} put failed: #{inspect(reason)}; reconnecting")
        teardown(state)
        send(self(), {:connect, @reconnect_initial_ms})
        {:noreply, drop_session(state)}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info(%Zenohex.Sample{key_expr: key_expr, payload: payload}, state) do
    case match_subscription(state.subscriptions, key_expr) do
      {:ok, sub} ->
        deliver_sample(sub, key_expr, payload)

      :no_match ->
        Logger.debug("#{__MODULE__} sample with no matching subscription: #{key_expr}")
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: teardown(state)

  defp deliver_sample(sub, key_expr, payload) do
    case sub.msg_module.parse(payload) do
      {:ok, parsed, _rest} ->
        Enum.each(sub.pids, fn pid ->
          send(pid, {:ros_message, {key_expr, parsed}})
        end)

      error ->
        Logger.warning(
          "#{__MODULE__} parse #{inspect(sub.msg_module)} on #{key_expr} failed: " <>
            inspect(error)
        )
    end
  end

  defp build_message(RosString, counter) do
    %RosString{data: "heartbeat #{counter} @ #{System.system_time(:millisecond)}"}
  end

  defp open_session(endpoint_ip) do
    with config <- Zenohex.Config.default(),
         {:ok, config} <- Zenohex.Config.insert_json5(config, "mode", "client"),
         {:ok, config} <-
           Zenohex.Config.insert_json5(
             config,
             "connect/endpoints",
             ~s(["tcp/#{endpoint_ip}:#{@zenoh_port}"])
           ) do
      Zenohex.Session.open(config)
    end
  end

  defp schedule_reconnect(state, backoff_ms, msg) do
    next = min(backoff_ms * 2, @reconnect_max_ms)

    Logger.warning(
      "#{__MODULE__} #{msg}; retrying in #{backoff_ms}ms"
    )

    Process.send_after(self(), {:connect, next}, backoff_ms)
    {:noreply, drop_session(state)}
  end

  defp teardown(%State{} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.liveliness_token, do: Zenohex.Liveliness.undeclare_token(state.liveliness_token)
    if state.publisher, do: Zenohex.Publisher.undeclare(state.publisher)

    Enum.each(state.subscriptions, fn {_k, sub} ->
      if sub.subscriber_id, do: Zenohex.Subscriber.undeclare(sub.subscriber_id)
    end)

    if state.session, do: Zenohex.Session.close(state.session)
    :ok
  end

  # Wipes per-connection refs so the next connect attempt starts from
  # a clean slate. Subscriptions are preserved (re-declared on the
  # next successful connect); their stale subscriber_ids are cleared
  # since they belonged to the dead session.
  defp drop_session(%State{} = state) do
    subscriptions =
      Map.new(state.subscriptions, fn {k, sub} -> {k, %{sub | subscriber_id: nil}} end)

    %{
      state
      | session: nil,
        publisher: nil,
        liveliness_token: nil,
        timer: nil,
        subscriptions: subscriptions
    }
  end

  # Wildcard match on `<domain>/<topic>/**` — fine because one topic
  # carries one type and we control both sides of the wire. Robust to
  # type-hash drift across ROS 2 distros. If we ever need exact
  # rmw_zenoh keyexprs, `Ros2.RmwZenoh.key_expr/3` already produces
  # them.
  defp subscription_key_expr(domain_id, topic) do
    "#{domain_id}/#{String.trim_leading(topic, "/")}/**"
  end

  defp declare_subscriber(session, key_expr) do
    Zenohex.Session.declare_subscriber(session, key_expr, self(), [])
  end

  defp redeclare_subscribers(session, subscriptions) do
    Map.new(subscriptions, fn {key_expr, sub} ->
      case declare_subscriber(session, key_expr) do
        {:ok, id} ->
          Logger.info("#{__MODULE__} (re)subscribed to #{key_expr}")
          {key_expr, %{sub | subscriber_id: id}}

        {:error, reason} ->
          Logger.warning(
            "#{__MODULE__} re-declare_subscriber #{key_expr} failed: #{inspect(reason)}"
          )

          {key_expr, %{sub | subscriber_id: nil}}
      end
    end)
  end

  # The registered keyexpr ends in `/**` — strip it and match by
  # prefix so the incoming Sample's concrete keyexpr (which embeds
  # the type name + hash chosen by the publisher) routes back to the
  # registered subscription.
  defp match_subscription(subscriptions, sample_key) do
    Enum.find_value(subscriptions, :no_match, fn {key_expr, sub} ->
      prefix = String.trim_trailing(key_expr, "/**")

      if String.starts_with?(sample_key, prefix <> "/") or sample_key == prefix do
        {:ok, sub}
      end
    end)
  end
end
