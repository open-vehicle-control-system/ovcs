defmodule ZenohMQTTRos2.Dispatcher.State do
  defstruct [:endpoint_ip, :mqtt_pid, :mqtt_ref, subscribers: %{}]
end

defmodule ZenohMQTTRos2.Dispatcher do
  @moduledoc false
  use GenServer
  alias ZenohMQTTRos2.Dispatcher.State
  require Logger

  # The broker may not be reachable when the bridge boots (no network
  # yet, broker rebooting, …). Keep trying with a bounded backoff
  # instead of crashing the bridge's whole supervision tree.
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    endpoint_ip = Keyword.fetch!(opts, :endpoint_ip)
    # `:emqtt.start_link/1` links the broker client to us. Trap exits
    # so a failed connect / dropped TCP / `:emqtt.stop` doesn't take
    # the Dispatcher down — we want to retry, not crash.
    Process.flag(:trap_exit, true)
    Logger.debug("zenoh endpoint: #{inspect(endpoint_ip)}")
    send(self(), {:connect, @reconnect_initial_ms})
    {:ok, %State{endpoint_ip: endpoint_ip}}
  end

  @impl true
  def handle_info({:connect, backoff_ms}, state) do
    client_id = "zenoh_mqtt_ros2_dispatcher_#{:rand.uniform(1_000_000)}"

    {:ok, pid} =
      :emqtt.start_link([
        {:host, state.endpoint_ip},
        {:port, 1883},
        {:clientid, client_id},
        {:clean_start, true}
      ])

    case :emqtt.connect(pid) do
      {:ok, _} ->
        Logger.info("#{__MODULE__} connected to #{state.endpoint_ip}")
        ref = Process.monitor(pid)
        state = %{state | mqtt_pid: pid, mqtt_ref: ref}
        resubscribe(state)
        {:noreply, state}

      {:error, reason} ->
        next = min(backoff_ms * 2, @reconnect_max_ms)

        Logger.warning(
          "#{__MODULE__} connect to #{state.endpoint_ip} failed: #{inspect(reason)}; " <>
            "retrying in #{backoff_ms}ms"
        )

        # `:emqtt.start_link/1` links the client to us; if we leave it
        # dangling it'll keep its own reconnect loop racing ours. Tear
        # it down before scheduling the next attempt.
        _ = stop_emqtt(pid)
        Process.send_after(self(), {:connect, next}, backoff_ms)
        {:noreply, %{state | mqtt_pid: nil, mqtt_ref: nil}}
    end
  end

  def handle_info({:publish, %{topic: topic, payload: payload}}, state) do
    {:ok, parsed_message, _rest} =
      case extract_message_type(topic) do
        {:ok, "sensor_msgs/msg/joy"} ->
          Ros2.SensorMsgs.Msg.Joy.parse(payload)

        {:ok, "sensor_msgs/msg/imu"} ->
          Ros2.SensorMsgs.Msg.Imu.parse(payload)

        {:ok, "std_msgs/msg/string"} ->
          Ros2.StdMsgs.Msg.String.parse(payload)

        _ ->
          Logger.debug("Unknown topic: #{inspect(topic)}")
          :unknown
      end

    Enum.each(state.subscribers, fn {subscribed_topic, pids} ->
      Enum.each(pids, fn pid ->
        if String.starts_with?(topic, subscribed_topic) do
          send(pid, {:mqtt_message, {topic, parsed_message}})
        end
      end)
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{mqtt_ref: ref} = state) do
    Logger.warning("#{__MODULE__} MQTT client down: #{inspect(reason)}; scheduling reconnect")
    Process.send_after(self(), {:connect, @reconnect_initial_ms}, @reconnect_initial_ms)
    {:noreply, %{state | mqtt_pid: nil, mqtt_ref: nil}}
  end

  # We trap exits so emqtt's link doesn't drag the Dispatcher down.
  # If the linked emqtt client dies (init-time failure, broker drop,
  # `:emqtt.stop`), schedule a reconnect from the current state and
  # carry on. Other linked processes (none today) would re-raise.
  def handle_info({:EXIT, pid, reason}, %State{mqtt_pid: pid} = state) do
    Logger.warning("#{__MODULE__} MQTT client EXIT: #{inspect(reason)}; scheduling reconnect")
    Process.send_after(self(), {:connect, @reconnect_initial_ms}, @reconnect_initial_ms)
    {:noreply, %{state | mqtt_pid: nil, mqtt_ref: nil}}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  # Subscribers are tracked in our own state and (re)applied to emqtt
  # each time we (re)connect, so callers can subscribe at any point —
  # before the broker is reachable, between reconnects, etc.
  def handle_call({:start_subscriber, topic}, {from, _tag}, state) do
    subscribers =
      Map.update(state.subscribers, topic, [from], fn subs ->
        if from in subs, do: subs, else: subs ++ [from]
      end)

    if state.mqtt_pid do
      {:ok, _, _} = :emqtt.subscribe(state.mqtt_pid, [{topic <> "#", 0}])
    end

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def start_subscriber(topic) do
    GenServer.call(__MODULE__, {:start_subscriber, topic})
  end

  def start_publisher(_message_type, _topic) do
  end

  defp resubscribe(%State{mqtt_pid: pid, subscribers: subscribers}) when not is_nil(pid) do
    Enum.each(subscribers, fn {topic, _pids} ->
      {:ok, _, _} = :emqtt.subscribe(pid, [{topic <> "#", 0}])
    end)
  end

  defp resubscribe(_), do: :ok

  defp stop_emqtt(pid) do
    if Process.alive?(pid) do
      try do
        :emqtt.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp extract_message_type(topic) do
    parts = String.split(topic, "/")

    type_info =
      Enum.find(parts, fn part ->
        String.contains?(part, "::dds_::")
      end)

    case type_info do
      nil ->
        {:error, :type_not_found}

      type_info ->
        type_info
        |> String.replace("::dds_::", ".")
        |> String.replace("::", ".")
        |> String.trim_trailing("_")
        |> Macro.underscore()
        |> then(&{:ok, &1})
    end
  end
end
