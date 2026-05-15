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
    counter: 0
  ]
end

defmodule RosBridge.ZenohClient do
  @moduledoc """
  Native-Zenoh client (via `zenohex`) that publishes a heartbeat to
  the OVCS Zenoh fabric as a real ROS 2 `std_msgs/String` message.
  Uses `Ros2.RmwZenoh` to build the rmw_zenoh keyexpr, CDR-wrap the
  payload, and attach the publisher metadata that subscribers (e.g.
  `foxglove_bridge`, `ros2 topic echo`) require.
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

      timer = Process.send_after(self(), :tick, state.interval_ms)

      {:noreply,
       %{
         state
         | session: session,
           publisher: publisher,
           liveliness_token: token,
           timer: timer
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
        {:noreply, %{state | session: nil, publisher: nil, timer: nil}}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: teardown(state)

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
    {:noreply, %{state | session: nil, publisher: nil, timer: nil}}
  end

  defp teardown(%State{} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.liveliness_token, do: Zenohex.Liveliness.undeclare_token(state.liveliness_token)
    if state.publisher, do: Zenohex.Publisher.undeclare(state.publisher)
    if state.session, do: Zenohex.Session.close(state.session)
    :ok
  end
end
