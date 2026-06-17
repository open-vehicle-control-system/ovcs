defmodule RosBridge.ZenohClient.State do
  @moduledoc false

  defstruct [
    :endpoint_ip,
    :node_name,
    :domain_id,
    :session,
    # %{topic => %{
    #     message_module, key_expr, gid, publisher_id,
    #     liveliness_token, sequence_number
    #   }}
    # Per-topic state. `gid` and `sequence_number` are stable across
    # reconnects so subscribers see a consistent publisher identity;
    # `publisher_id` and `liveliness_token` are per-session and get
    # re-declared on every reconnect.
    publishers: %{},
    # %{key_expr => %{
    #     topic, message_module,
    #     subscribers: %{pid => monitor_ref},
    #     subscriber_id
    #   }}
    subscriptions: %{},
    # %{service_name => %{
    #     service_module, handler, key_expr,
    #     liveliness_key, queryable_id, liveliness_token
    #   }}
    # Per-service-server state. The handler is the pid that runs
    # the request → response logic; queryable_id +
    # liveliness_token are per-session and re-declared on reconnect.
    services: %{},
    # Reverse index for fast :DOWN lookup: monitor_ref → {key_expr, pid}.
    monitors: %{}
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
  """
  use GenServer

  alias RosBridge.ZenohClient.State
  alias Ros2.RmwZenoh

  require Logger

  @default_node_name "ovcs_bridge"
  @default_domain_id 0
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 30_000
  @zenoh_port 7447

  ## API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish `message` (a struct whose module implements `encode/1`,
  `dds_type/0`, `type_hash/0`) on the ROS 2 `topic`. The first call
  for a given topic lazily declares the underlying Zenoh publisher
  and its rmw_zenoh liveliness token; subsequent calls reuse them.

  Fire-and-forget — calls before the session is connected are
  dropped with a debug log (the heartbeat re-fires on its own timer,
  IMU streams self-recover on the next sample). Returns `:ok`
  immediately.
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

  @doc """
  Register a ROS 2 **service server** on `service_name` (e.g.
  `"/stereo/left/set_camera_info"`). The service module must
  expose `dds_type/0`, `type_hash/0`, and a `Request.parse/1`
  callable from the handler.

  Incoming queries are forwarded to `handler_pid` as
  `{:service_request, %{service_name, query, request_payload}}`,
  where `query` is the raw `%Zenohex.Query{}` (so the handler can
  pass it to `respond/3` once it has built the response).

  Safe to call before the session is open; the queryable is
  declared on the next successful connect and re-declared after any
  reconnect.
  """
  def register_service(service_name, service_module, handler_pid \\ self()) do
    GenServer.call(__MODULE__, {:register_service, service_name, service_module, handler_pid})
  end

  @doc """
  Reply to an in-flight service query with an already-encoded
  response payload (CDR-LE encapsulated). `service_name` is the
  same string passed to `register_service/3`; it's used to look up
  the data keyexpr the reply should be tagged with.
  """
  def respond(service_name, %Zenohex.Query{} = query, response_payload) do
    GenServer.cast(__MODULE__, {:respond, service_name, query, response_payload})
  end

  ## Callbacks

  @impl true
  def init(opts) do
    state = %State{
      endpoint_ip: Keyword.fetch!(opts, :endpoint_ip),
      node_name: Keyword.get(opts, :node_name, @default_node_name),
      domain_id: Keyword.get(opts, :domain_id, @default_domain_id)
    }

    send(self(), {:connect, @reconnect_initial_ms})
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, topic, message_module, pid, _opts}, _from, state) do
    key_expr = subscription_key_expr(state.domain_id, topic)

    subscription =
      Map.get(state.subscriptions, key_expr, %{
        topic: topic,
        message_module: message_module,
        subscribers: %{},
        subscriber_id: nil
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
        declare_subscriber(state.session, key_expr, subscription)
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

  def handle_call({:register_service, service_name, service_module, handler_pid}, _from, state) do
    service = build_service_record(state, service_name, service_module, handler_pid)
    state = put_in(state.services[service_name], service)

    state =
      if state.session do
        case declare_service(state, service_name, service) do
          {:ok, state, _service} -> state
          {:error, _reason, state} -> state
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:respond, service_name, query, response_payload}, state) do
    case Map.get(state.services, service_name) do
      nil ->
        Logger.warning("#{__MODULE__} respond on unknown service #{service_name}; dropping")
        {:noreply, state}

      service ->
        # rmw_zenoh's CDR encapsulation header on the response body.
        cdr = <<0x00, 0x01, 0x00, 0x00>> <> response_payload

        # The reply must carry an attachment that echoes the request's
        # sequence_id so the rclpy client can match it to the call
        # site. The request attachment layout matches our publisher
        # attachment (see `Ros2.RmwZenoh.attachment/3`): 8 bytes seq,
        # 8 bytes ns, 1 byte gid-len, 16 bytes gid. We echo the seq
        # and re-stamp the timestamp; the GID we re-use as the
        # writer-id stand-in.
        attachment =
          case query.attachment do
            <<seq::little-signed-integer-size(64), _ts::binary-size(8),
              16::unsigned-integer-size(8), gid::binary-size(16)>> ->
              RmwZenoh.attachment(seq, System.system_time(:nanosecond), gid)

            _ ->
              # No or unparseable request attachment — synthesise one.
              RmwZenoh.attachment(0, System.system_time(:nanosecond), :crypto.strong_rand_bytes(16))
          end

        case Zenohex.Query.reply(query.zenoh_query, service.key_expr, cdr, attachment: attachment) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "#{__MODULE__} reply on #{service.key_expr} failed: #{inspect(reason)}"
            )

            {:noreply, state}
        end
    end
  end

  def handle_cast({:publish, _topic, _message_module, _message, _opts}, %State{session: nil} = state) do
    Logger.debug("#{__MODULE__} publish dropped (no session yet)")
    {:noreply, state}
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
            # Sample the debug log: emit on the first put (so you
            # see each topic come alive) and once every 30 puts
            # after — at 30 Hz that's ~1 line/sec/topic instead of
            # the full firehose.
            if rem(publisher.sequence_number, 30) == 1 do
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
            {:noreply, drop_session(state)}
        end

      {:error, reason, state} ->
        Logger.warning(
          "#{__MODULE__} declare publisher for #{topic} failed: #{inspect(reason)}; " <>
            "dropping publish"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:connect, backoff_ms}, state) do
    case open_session(state.endpoint_ip) do
      {:ok, session} ->
        Logger.info(
          "#{__MODULE__} connected to tcp/#{state.endpoint_ip}:#{@zenoh_port}"
        )

        state = %{state | session: session}
        state = redeclare_publishers(state)
        state = redeclare_subscribers(state)
        state = redeclare_services(state)
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

  def handle_info(%Zenohex.Query{key_expr: key_expr} = query, state) do
    case match_service(state.services, key_expr) do
      {:ok, service_name, service} ->
        request_payload =
          case RmwZenoh.decode_payload(query.payload || <<>>) do
            {:ok, decoded} -> decoded
            _ -> query.payload
          end

        Logger.debug(
          "#{__MODULE__} query on #{service_name} " <>
            "(payload #{byte_size(query.payload || <<>>)}B, " <>
            "attachment #{byte_size(query.attachment || <<>>)}B)"
        )

        send(
          service.handler,
          {:service_request,
           %{service_name: service_name, query: query, request_payload: request_payload}}
        )

      :no_match ->
        Logger.debug("#{__MODULE__} query with no matching service: #{key_expr}")
        Zenohex.Query.reply_error(query.zenoh_query, "no handler")
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

  @impl true
  def terminate(_reason, state), do: teardown_session(state)

  ## Internals — subscribers

  defp subscription_key_expr(domain_id, topic) do
    # Wildcard match on `<domain>/<topic>/**`. One topic carries one
    # type in the OVCS bus, so type-hash drift between ROS distros
    # doesn't break us — the message module's `parse/1` is the only
    # type-aware step on the subscriber side.
    "#{domain_id}/#{String.trim_leading(topic, "/")}/**"
  end

  defp declare_subscriber(session, key_expr, subscription) do
    case Zenohex.Session.declare_subscriber(session, key_expr, self(), []) do
      {:ok, subscriber_id} ->
        Logger.info("#{__MODULE__} subscribed to #{key_expr}")
        %{subscription | subscriber_id: subscriber_id}

      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__} declare_subscriber #{key_expr} failed: #{inspect(reason)}"
        )

        subscription
    end
  end

  defp redeclare_subscribers(%State{session: session} = state) do
    subscriptions =
      Map.new(state.subscriptions, fn {key_expr, subscription} ->
        subscription = %{subscription | subscriber_id: nil}
        {key_expr, declare_subscriber(session, key_expr, subscription)}
      end)

    %{state | subscriptions: subscriptions}
  end

  # The registered key_expr ends in `/**` — strip it and match by
  # prefix so the incoming Sample's concrete key_expr (which embeds
  # the type name + hash chosen by the publisher) routes back.
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
         {:ok, parsed, _rest} <- subscription.message_module.parse(body) do
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

            Logger.info("#{__MODULE__} unsubscribed from #{key_expr} (no consumers left)")
            {Map.delete(state.subscriptions, key_expr), subscription}
          else
            {Map.put(state.subscriptions, key_expr, subscription), subscription}
          end

        {%{state | subscriptions: subscriptions, monitors: monitors}, subscription}
    end
  end

  ## Internals — services

  defp build_service_record(state, service_name, service_module, handler_pid) do
    key_expr = RmwZenoh.service_key_expr(state.domain_id, service_name, service_module)

    %{
      service_module: service_module,
      handler: handler_pid,
      key_expr: key_expr,
      liveliness_key: nil,
      queryable_id: nil,
      liveliness_token: nil
    }
  end

  defp declare_service(state, service_name, service) do
    with {:ok, %Zenohex.Session.Info{zid: zid}} <- Zenohex.Session.info(state.session),
         {:ok, queryable_id} <-
           Zenohex.Session.declare_queryable(
             state.session,
             service.key_expr,
             self(),
             complete: true
           ),
         liveliness_key <-
           RmwZenoh.service_liveliness_key(
             state.domain_id,
             zid,
             state.node_name,
             service_name,
             service.service_module
           ),
         {:ok, liveliness_token} <-
           Zenohex.Liveliness.declare_token(state.session, liveliness_key) do
      Logger.info(
        "#{__MODULE__} service #{inspect(service.service_module)} on #{service.key_expr} " <>
          "(liveliness #{liveliness_key})"
      )

      service = %{
        service
        | queryable_id: queryable_id,
          liveliness_token: liveliness_token,
          liveliness_key: liveliness_key
      }

      state = put_in(state.services[service_name], service)
      {:ok, state, service}
    else
      {:error, reason} ->
        Logger.warning(
          "#{__MODULE__} declare service #{service_name} failed: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp redeclare_services(%State{session: nil} = state), do: state

  defp redeclare_services(%State{} = state) do
    Enum.reduce(state.services, state, fn {service_name, service}, acc ->
      service = %{service | queryable_id: nil, liveliness_token: nil}

      case declare_service(acc, service_name, service) do
        {:ok, acc, _} -> acc
        {:error, _reason, acc} -> acc
      end
    end)
  end

  # The registered service key_expr is a single concrete string —
  # match incoming query.key_expr against it exactly.
  defp match_service(services, query_key) do
    Enum.find_value(services, :no_match, fn {service_name, service} ->
      if service.key_expr == query_key do
        {:ok, service_name, service}
      end
    end)
  end

  ## Internals — publishers

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
         {:ok, liveliness_token} <- Zenohex.Liveliness.declare_token(state.session, liveliness_key) do
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

  defp redeclare_publishers(%State{session: nil} = state), do: state

  defp redeclare_publishers(%State{} = state) do
    Enum.reduce(state.publishers, state, fn {topic, publisher}, acc ->
      case redeclare_publisher(acc, topic, publisher) do
        {:ok, acc, _} ->
          acc

        {:error, reason, acc} ->
          Logger.warning(
            "#{__MODULE__} re-declare publisher #{topic} failed: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp put_publisher(state, topic, publisher) do
    %{state | publishers: Map.put(state.publishers, topic, publisher)}
  end

  ## Internals — session

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

  defp schedule_reconnect(state, backoff_ms, reason) do
    next = min(backoff_ms * 2, @reconnect_max_ms)

    Logger.warning("#{__MODULE__} #{reason}; retrying in #{backoff_ms}ms")
    Process.send_after(self(), {:connect, next}, backoff_ms)
    {:noreply, drop_session(state)}
  end

  defp teardown_session(%State{} = state) do
    Enum.each(state.publishers, fn {_topic, publisher} ->
      if publisher.liveliness_token,
        do: Zenohex.Liveliness.undeclare_token(publisher.liveliness_token)

      if publisher.publisher_id, do: Zenohex.Publisher.undeclare(publisher.publisher_id)
    end)

    Enum.each(state.subscriptions, fn {_key_expr, subscription} ->
      if subscription.subscriber_id,
        do: Zenohex.Subscriber.undeclare(subscription.subscriber_id)
    end)

    Enum.each(state.services, fn {_name, service} ->
      if service.liveliness_token,
        do: Zenohex.Liveliness.undeclare_token(service.liveliness_token)

      if service.queryable_id, do: Zenohex.Queryable.undeclare(service.queryable_id)
    end)

    if state.session, do: Zenohex.Session.close(state.session)
    :ok
  end

  # Clears per-session refs without dropping the durable identity
  # bits (gid, sequence_number, registered subscribers, service handlers).
  defp drop_session(%State{} = state) do
    publishers =
      Map.new(state.publishers, fn {topic, publisher} ->
        {topic, %{publisher | publisher_id: nil, liveliness_token: nil}}
      end)

    subscriptions =
      Map.new(state.subscriptions, fn {key_expr, subscription} ->
        {key_expr, %{subscription | subscriber_id: nil}}
      end)

    services =
      Map.new(state.services, fn {service_name, service} ->
        {service_name, %{service | queryable_id: nil, liveliness_token: nil}}
      end)

    %{state | session: nil, publishers: publishers, subscriptions: subscriptions, services: services}
  end
end
