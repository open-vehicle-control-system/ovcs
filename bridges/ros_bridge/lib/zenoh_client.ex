defmodule RosBridge.ZenohClient.State do
  @moduledoc """
  `RosBridge.ZenohClient`'s state.

    * `node_token`: the node's own liveliness token, per session.
      Without it rmw_zenoh infers the node from its entities.
    * `publishers`: `%{topic => %{message_module, key_expr, gid,
      publisher_id, liveliness_token, sequence_number}}`. `gid` and
      `sequence_number` survive reconnects so subscribers see one
      publisher identity; `publisher_id` and `liveliness_token` are
      per session.
    * `subscriptions`: `%{key_expr => %{topic, message_module,
      subscribers: %{pid => monitor_ref}, subscriber_id,
      liveliness_token, eid}}`.
    * `monitors`: `%{monitor_ref => {key_expr, pid}}`, for `:DOWN`.
    * `drops_while_offline`: publishes dropped while no session is
      open, logged once on connect, then reset.
  """

  defstruct [
    :endpoint_ip,
    :node_name,
    :domain_id,
    :session,
    :node_token,
    publishers: %{},
    subscriptions: %{},
    monitors: %{},
    drops_while_offline: 0
  ]
end

defmodule RosBridge.ZenohClient do
  @moduledoc """
  Thin wrapper around a single `zenohex` session, shared by every
  publisher and subscriber in `ros_bridge`. Handles three concerns:

    * Connecting to the configured Zenoh router with bounded-backoff
      reconnect.
    * Lazily declaring per-topic publishers (`publish/4`) and their
      matching rmw_zenoh liveliness tokens so ROS 2 graph introspection
      (`ros2 topic list`, Foxglove) sees them.
    * Tracking subscribers (`subscribe/4` / `unsubscribe/2`), monitoring
      their pids so a crashing consumer cleans up after itself.

  The actual ROS 2 message generation (heartbeats, IMU, etc.) lives in
  caller GenServers — `RosBridge.Publishers.Heartbeat`, `RosBridge.Consumers.Joy`,
  and friends — that use the API exposed here.

  ## Subscriptions

  A subscription matches `<domain>/<topic>/**` rather than the exact
  `<domain>/<topic>/<type>/<hash>` keyexpr. `rmw_zenoh_cpp` appends a
  per-subscriber `/_buf/<id>` segment to the data keyexpr, which an
  exact match never receives, and one topic carries one type, so
  type-hash drift between ROS distributions does not matter: the
  message module's `parse/1` is the only type-aware step. The cost is
  that `/**` also matches copies a publisher addresses to *other*
  subscribers, so a second consumer of the same topic makes the bridge
  handle each sample twice; deduplicate on the header stamp rather
  than narrowing the pattern, since the buffer id is not predictable.

  Each subscription also declares a liveliness token. Receiving data
  does not need it, but publishers that only send when someone is
  listening (`image_transport`'s compressed transports, anything using
  `count_subscribers()`) stay silent without it. A token that cannot be
  declared, or a message module without `dds_type/0` and
  `type_hash/0`, is logged and skipped: the subscription still
  receives from ordinary publishers.

  ## Parsing

  Every message module is entered through one guarded call. The
  parsers are binary pattern matches, and a short or malformed body
  raises (`FunctionClauseError`, `MatchError`, `ArgumentError`) rather
  than returning a tagged error. The bridge subtree is `:rest_for_one`
  (`RosBridge.children/0`), so a raise would restart every consumer at
  the publisher's frequency; a malformed frame is data, not a fault.

  Bytes left over after a successful parse mean the wrong message
  module: a `TwistStamped` body handed to `Twist.parse/1` reads the
  header as float64s and succeeds with denormals, so the vehicle
  ignores every command while the stream looks healthy. Messages ending
  in a variable-length field can carry up to 7 bytes of CDR alignment
  padding, so only a surplus of 8 bytes or more is warned about, at
  most once per period per keyexpr.
  """
  use GenServer

  alias RosBridge.ZenohClient.State
  alias Ros2Zenoh.RmwZenoh

  require Logger

  @default_node_name "ovcs_bridge"
  @default_domain_id 0
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 30_000
  # zenohd's default listener.
  @zenoh_port 7447
  @surplus_warning_period_ms 5_000
  # Trailing CDR padding is at most 7 bytes.
  @surplus_alignment_slack_bytes 8
  # Logs a topic's first put, then one in this many.
  @debug_log_every_puts 30

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish `message` (a struct whose module implements `encode/1`,
  `dds_type/0`, `type_hash/0`) on the ROS 2 `topic`. The first call
  for a given topic lazily declares the underlying Zenoh publisher
  and its rmw_zenoh liveliness token; subsequent calls reuse them.

  Fire-and-forget — calls before the session is connected are dropped
  silently and tallied (the heartbeat re-fires on its own timer, IMU
  streams self-recover on the next sample); the drop count is logged
  once when the session opens. Returns `:ok` immediately.
  """
  def publish(topic, message_module, message, opts \\ []) do
    GenServer.cast(__MODULE__, {:publish, topic, message_module, message, opts})
  end

  @doc """
  Subscribe `pid` (defaults to the calling process) to ROS 2 `topic`.
  Incoming samples are CDR-decoded with `message_module.parse/1` and
  delivered as `{:ros_message, {key_expr, parsed_message}}`.

  Safe to call before the session is open; the subscription is declared
  on the next successful connect and re-declared after any reconnect.
  The subscriber pid is monitored — when it dies its registration is
  cleaned up automatically, and the Zenoh subscriber is undeclared once
  no consumers remain.
  """
  def subscribe(topic, message_module, pid \\ self(), opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, topic, message_module, pid, opts})
  end

  @doc """
  Remove `pid` from `topic`'s subscriber set. If no subscribers remain
  the underlying Zenoh subscriber is undeclared.
  """
  def unsubscribe(topic, pid \\ self()) do
    GenServer.call(__MODULE__, {:unsubscribe, topic, pid})
  end

  @doc "The ROS node name this client declares its entities under."
  def node_name, do: GenServer.call(__MODULE__, :node_name)

  @impl GenServer
  def init(opts) do
    state = %State{
      endpoint_ip: Keyword.fetch!(opts, :endpoint_ip),
      node_name: Keyword.get(opts, :node_name, @default_node_name),
      domain_id: Keyword.get(opts, :domain_id, @default_domain_id)
    }

    send(self(), {:connect, @reconnect_initial_ms})
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:node_name, _from, state), do: {:reply, state.node_name, state}

  def handle_call({:subscribe, topic, message_module, pid, _opts}, _from, state) do
    key_expr = subscription_key_expr(state.domain_id, topic)

    subscription =
      Map.get(state.subscriptions, key_expr, %{
        topic: topic,
        message_module: message_module,
        subscribers: %{},
        subscriber_id: nil,
        liveliness_token: nil,
        # Unique per entity within the session; see
        # RmwZenoh.subscriber_liveliness_key/6.
        eid: map_size(state.subscriptions) + 1
      })

    {subscription, monitors} =
      if Map.has_key?(subscription.subscribers, pid) do
        {subscription, state.monitors}
      else
        monitor_ref = Process.monitor(pid)

        subscription = %{
          subscription
          | subscribers: Map.put(subscription.subscribers, pid, monitor_ref)
        }

        monitors = Map.put(state.monitors, monitor_ref, {key_expr, pid})
        {subscription, monitors}
      end

    subscription =
      if state.session && is_nil(subscription.subscriber_id) do
        declare_subscriber(state, key_expr, subscription)
      else
        subscription
      end

    state = %{
      state
      | subscriptions: Map.put(state.subscriptions, key_expr, subscription),
        monitors: monitors
    }

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    key_expr = subscription_key_expr(state.domain_id, topic)

    case Map.get(state.subscriptions, key_expr) do
      nil ->
        {:reply, :ok, state}

      subscription ->
        {state, _} = drop_subscriber(state, key_expr, subscription, pid)
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast(
        {:publish, _topic, _message_module, _message, _opts},
        %State{session: nil} = state
      ) do
    # Fire-and-forget: drop silently and tally. Publishers re-fire on
    # their own timers, so a per-drop log just spams while the router is
    # unreachable. The count is summarised when the session opens.
    {:noreply, %{state | drops_while_offline: state.drops_while_offline + 1}}
  end

  def handle_cast({:publish, topic, message_module, message, _opts}, state) do
    case ensure_publisher(state, topic, message_module) do
      {:ok, state, publisher} ->
        publisher = %{publisher | sequence_number: publisher.sequence_number + 1}
        payload = RmwZenoh.encode_payload(message)

        attachment =
          RmwZenoh.attachment(
            publisher.sequence_number,
            System.system_time(:nanosecond),
            publisher.gid
          )

        case Zenohex.Publisher.put(publisher.publisher_id, payload, attachment: attachment) do
          :ok ->
            if rem(publisher.sequence_number, @debug_log_every_puts) == 1 do
              Logger.debug(
                "#{__MODULE__} put ##{publisher.sequence_number} on #{publisher.key_expr} " <>
                  "(#{byte_size(payload)}B payload)"
              )
            end

            state = put_publisher(state, topic, publisher)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "#{__MODULE__} put on #{publisher.key_expr} failed: #{inspect(reason)}; " <>
                "reconnecting"
            )

            teardown_session(state)
            send(self(), {:connect, @reconnect_initial_ms})
            {:noreply, clear_session_handles(state)}
        end

      {:error, reason, state} ->
        Logger.warning(
          "#{__MODULE__} declare publisher for #{topic} failed: #{inspect(reason)}; " <>
            "dropping publish"
        )

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:connect, backoff_ms}, state) do
    case open_session(state.endpoint_ip) do
      {:ok, session} ->
        Logger.info("#{__MODULE__} connected to tcp/#{state.endpoint_ip}:#{@zenoh_port}")

        if state.drops_while_offline > 0 do
          Logger.debug(
            "#{__MODULE__} dropped #{state.drops_while_offline} publish(es) before session opened"
          )
        end

        state = %{state | session: session, drops_while_offline: 0}
        state = declare_node(state)
        state = redeclare_publishers(state)
        state = redeclare_subscribers(state)
        {:noreply, state}

      {:error, reason} ->
        schedule_reconnect(state, backoff_ms, "connect failed: #{inspect(reason)}")
    end
  end

  def handle_info(%Zenohex.Sample{key_expr: key_expr, payload: payload}, state) do
    case match_subscription(state.subscriptions, key_expr) do
      {:ok, subscription} ->
        deliver_sample(subscription, key_expr, payload)

      :no_match ->
        Logger.debug("#{__MODULE__} sample with no matching subscription: #{key_expr}")
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _} ->
        {:noreply, state}

      {{key_expr, pid}, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.subscriptions, key_expr) do
          nil ->
            {:noreply, state}

          subscription ->
            {state, _} = drop_subscriber(state, key_expr, subscription, pid)
            {:noreply, state}
        end
    end
  end

  @impl GenServer
  def terminate(_reason, state), do: teardown_session(state)

  defp subscription_key_expr(domain_id, topic) do
    # Wildcard, as explained in the moduledoc.
    "#{domain_id}/#{String.trim_leading(topic, "/")}/**"
  end

  defp declare_subscriber(%State{session: session} = state, key_expr, subscription) do
    case Zenohex.Session.declare_subscriber(session, key_expr, self(), []) do
      {:ok, subscriber_id} ->
        Logger.info("#{__MODULE__} subscribed to #{key_expr}")

        %{subscription | subscriber_id: subscriber_id}
        |> maybe_declare_subscriber_liveliness(state)

      {:error, reason} ->
        Logger.warning("#{__MODULE__} declare_subscriber #{key_expr} failed: #{inspect(reason)}")

        subscription
    end
  end

  # Announces the subscription in the ROS graph, when its module names a type.
  defp maybe_declare_subscriber_liveliness(subscription, %State{} = state) do
    module = subscription.message_module
    Code.ensure_loaded(module)

    if function_exported?(module, :dds_type, 0) and function_exported?(module, :type_hash, 0) do
      declare_subscriber_liveliness_token(subscription, state)
    else
      Logger.debug(
        "#{__MODULE__} #{inspect(module)} declares no dds_type/type_hash; " <>
          "subscribing to #{subscription.topic} without a liveliness token"
      )

      subscription
    end
  end

  defp declare_subscriber_liveliness_token(subscription, %State{session: session} = state) do
    with {:ok, %Zenohex.Session.Info{zid: zid}} <- Zenohex.Session.info(session),
         liveliness_key <-
           RmwZenoh.subscriber_liveliness_key(
             state.domain_id,
             zid,
             state.node_name,
             subscription.topic,
             subscription.message_module,
             subscription.eid
           ),
         {:ok, token} <- Zenohex.Liveliness.declare_token(session, liveliness_key) do
      Logger.debug("#{__MODULE__} subscriber liveliness #{liveliness_key}")
      %{subscription | liveliness_token: token}
    else
      error ->
        Logger.warning(
          "#{__MODULE__} subscriber liveliness for #{subscription.topic} failed: " <>
            "#{inspect(error)}; lazy publishers will not see us"
        )

        subscription
    end
  end

  defp redeclare_subscribers(%State{} = state) do
    subscriptions =
      Map.new(state.subscriptions, fn {key_expr, subscription} ->
        # The old token belongs to the dead session; drop it so a new
        # one is declared rather than leaking the stale handle.
        subscription = %{subscription | subscriber_id: nil, liveliness_token: nil}
        {key_expr, declare_subscriber(state, key_expr, subscription)}
      end)

    %{state | subscriptions: subscriptions}
  end

  # Prefix match: a sample's key_expr carries the publisher's type and hash.
  defp match_subscription(subscriptions, sample_key) do
    Enum.find_value(subscriptions, :no_match, fn {key_expr, subscription} ->
      prefix = String.trim_trailing(key_expr, "/**")

      if String.starts_with?(sample_key, prefix <> "/") or sample_key == prefix do
        {:ok, subscription}
      end
    end)
  end

  defp deliver_sample(subscription, key_expr, payload) do
    with {:ok, body} <- RmwZenoh.decode_payload(payload),
         {:ok, parsed, rest} <- parse_body(subscription.message_module, body) do
      warn_on_surplus(subscription.message_module, key_expr, rest)

      Enum.each(subscription.subscribers, fn {pid, _ref} ->
        send(pid, {:ros_message, {key_expr, parsed}})
      end)
    else
      error ->
        Logger.warning(
          "#{__MODULE__} parse #{inspect(subscription.message_module)} on #{key_expr} " <>
            "failed: #{inspect(error)}"
        )
    end
  end

  # A raising parser must not crash the client; see the moduledoc.
  defp parse_body(message_module, body) do
    message_module.parse(body)
  rescue
    exception ->
      {:error, {:parse_raised, Exception.message(exception), byte_size(body)}}
  end

  # Surplus bytes mean the wrong message module; see the moduledoc.
  defp warn_on_surplus(message_module, key_expr, rest)
       when byte_size(rest) >= @surplus_alignment_slack_bytes do
    now_ms = System.monotonic_time(:millisecond)
    warned_key = {:surplus_warned, key_expr}
    last_warning_ms = Process.get(warned_key)

    # Test nil, not a sentinel: monotonic time is often negative.
    if is_nil(last_warning_ms) or now_ms - last_warning_ms >= @surplus_warning_period_ms do
      Process.put(warned_key, now_ms)

      Logger.warning(
        "#{__MODULE__} #{inspect(message_module)} parsed #{key_expr} but left " <>
          "#{byte_size(rest)} bytes unread, which usually means the publisher is " <>
          "sending a different message type -- a stamped variant, most often"
      )
    end

    :ok
  end

  defp warn_on_surplus(_message_module, _key_expr, _rest), do: :ok

  defp drop_subscriber(state, key_expr, subscription, pid) do
    case Map.pop(subscription.subscribers, pid) do
      {nil, _} ->
        {state, subscription}

      {monitor_ref, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])
        monitors = Map.delete(state.monitors, monitor_ref)
        subscription = %{subscription | subscribers: subscribers}

        {subscriptions, subscription} =
          if subscribers == %{} do
            if subscription.subscriber_id do
              Zenohex.Subscriber.undeclare(subscription.subscriber_id)
            end

            if subscription.liveliness_token do
              Zenohex.Liveliness.undeclare_token(subscription.liveliness_token)
            end

            Logger.info("#{__MODULE__} unsubscribed from #{key_expr} (no consumers left)")
            {Map.delete(state.subscriptions, key_expr), subscription}
          else
            {Map.put(state.subscriptions, key_expr, subscription), subscription}
          end

        {%{state | subscriptions: subscriptions, monitors: monitors}, subscription}
    end
  end

  defp ensure_publisher(state, topic, message_module) do
    case Map.get(state.publishers, topic) do
      nil ->
        declare_publisher(state, topic, message_module)

      %{publisher_id: nil} = publisher ->
        # Known topic, but the publisher_id was cleared by a reconnect
        # before the next publish — re-declare against the new session,
        # keeping the stable gid + sequence_number.
        redeclare_publisher(state, topic, publisher)

      publisher ->
        {:ok, state, publisher}
    end
  end

  defp declare_publisher(state, topic, message_module) do
    key_expr = RmwZenoh.key_expr(state.domain_id, topic, message_module)
    gid = RmwZenoh.random_gid()

    with {:ok, %Zenohex.Session.Info{zid: zid}} <- Zenohex.Session.info(state.session),
         {:ok, publisher_id} <- Zenohex.Session.declare_publisher(state.session, key_expr, []),
         liveliness_key <-
           RmwZenoh.liveliness_key(
             state.domain_id,
             zid,
             state.node_name,
             topic,
             message_module
           ),
         {:ok, liveliness_token} <-
           Zenohex.Liveliness.declare_token(state.session, liveliness_key) do
      Logger.info(
        "#{__MODULE__} publishing #{inspect(message_module)} on #{key_expr} " <>
          "(liveliness token #{liveliness_key})"
      )

      publisher = %{
        message_module: message_module,
        key_expr: key_expr,
        gid: gid,
        publisher_id: publisher_id,
        liveliness_token: liveliness_token,
        sequence_number: 0
      }

      {:ok, put_publisher(state, topic, publisher), publisher}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp redeclare_publisher(state, topic, %{message_module: message_module} = previous) do
    case declare_publisher(state, topic, message_module) do
      {:ok, state, fresh} ->
        # Preserve the publisher's identity across reconnects so
        # rmw_zenoh subscribers don't see a new publisher GID for
        # every TCP blip.
        publisher = %{fresh | gid: previous.gid, sequence_number: previous.sequence_number}
        {:ok, put_publisher(state, topic, publisher), publisher}

      error ->
        error
    end
  end

  defp redeclare_publishers(%State{} = state) do
    Enum.reduce(state.publishers, state, fn {topic, publisher}, updated_state ->
      case redeclare_publisher(updated_state, topic, publisher) do
        {:ok, updated_state, _} ->
          updated_state

        {:error, reason, updated_state} ->
          Logger.warning("#{__MODULE__} re-declare publisher #{topic} failed: #{inspect(reason)}")

          updated_state
      end
    end)
  end

  defp put_publisher(state, topic, publisher) do
    %{state | publishers: Map.put(state.publishers, topic, publisher)}
  end

  defp open_session(endpoint_ip) do
    Zenohex.Config.default()
    |> Zenohex.Config.update_in(["mode"], fn _ -> "client" end)
    |> Zenohex.Config.update_in(["connect", "endpoints"], fn _ ->
      ["tcp/#{endpoint_ip}:#{@zenoh_port}"]
    end)
    |> Zenohex.Session.open()
  end

  defp schedule_reconnect(state, backoff_ms, reason) do
    next_backoff_ms = min(backoff_ms * 2, @reconnect_max_ms)

    Logger.warning("#{__MODULE__} #{reason}; retrying in #{backoff_ms}ms")
    Process.send_after(self(), {:connect, next_backoff_ms}, backoff_ms)
    {:noreply, clear_session_handles(state)}
  end

  defp teardown_session(%State{} = state) do
    if state.node_token, do: Zenohex.Liveliness.undeclare_token(state.node_token)

    Enum.each(state.publishers, fn {_topic, publisher} ->
      if publisher.liveliness_token,
        do: Zenohex.Liveliness.undeclare_token(publisher.liveliness_token)

      if publisher.publisher_id, do: Zenohex.Publisher.undeclare(publisher.publisher_id)
    end)

    Enum.each(state.subscriptions, fn {_key_expr, subscription} ->
      if subscription.subscriber_id,
        do: Zenohex.Subscriber.undeclare(subscription.subscriber_id)
    end)

    if state.session, do: Zenohex.Session.close(state.session)
    :ok
  end

  defp declare_node(state) do
    with {:ok, %Zenohex.Session.Info{zid: zid}} <- Zenohex.Session.info(state.session),
         liveliness_key = RmwZenoh.node_liveliness_key(state.domain_id, zid, state.node_name),
         {:ok, token} <- Zenohex.Liveliness.declare_token(state.session, liveliness_key) do
      %{state | node_token: token}
    else
      error ->
        Logger.warning("#{__MODULE__} node token not declared: #{inspect(error)}")
        state
    end
  end

  # Keeps gids, sequence numbers and subscribers.
  defp clear_session_handles(%State{} = state) do
    publishers =
      Map.new(state.publishers, fn {topic, publisher} ->
        {topic, %{publisher | publisher_id: nil, liveliness_token: nil}}
      end)

    subscriptions =
      Map.new(state.subscriptions, fn {key_expr, subscription} ->
        {key_expr, %{subscription | subscriber_id: nil}}
      end)

    %{
      state
      | session: nil,
        node_token: nil,
        publishers: publishers,
        subscriptions: subscriptions
    }
  end
end
