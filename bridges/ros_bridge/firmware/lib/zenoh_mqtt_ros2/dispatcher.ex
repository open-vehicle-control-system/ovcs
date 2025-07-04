defmodule ZenohMQTTRos2.Dispatcher.State do
  defstruct [:mqtt_pid, :subscribers]
end

defmodule ZenohMQTTRos2.Dispatcher do
  @moduledoc false
  use GenServer
  alias ZenohMQTTRos2.Dispatcher.State
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    zenoh_endpoint_ip = Application.get_env(:ros_bridge_firmware, :zenoh_endpoint_ip) |> IO.inspect
    client_id = "zenoh_mqtt_ros2_dispatcher_#{:rand.uniform(1000)}"
    :timer.sleep(5000)
    {:ok, pid} = :emqtt.start_link([
      {:host, zenoh_endpoint_ip},
      {:port, 1883},
      {:clientid, client_id},
      {:clean_start, true}
    ])

    case :emqtt.connect(pid) do
      {:ok, _} ->
        Logger.debug("Starting #{__MODULE__}...")
        Process.monitor(pid)
        {:ok,
          %State{
            mqtt_pid: pid,
            subscribers: %{}
          }
        }
      {:error, reason} ->
        Logger.error("#{__MODULE__} failed to connect: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:publish, %{topic: topic, payload: payload}}, state) do
    # Logger.debug("#{__MODULE__} received on topic: #{topic}")

    {:ok, parsed_message, _rest} =
      case extract_message_type(topic) do
        {:ok, "sensor_msgs/msg/joy"} ->
          Ros2.SensorMsgs.Msg.Joy.parse(payload)
        {:ok, "sensor_msgs/msg/imu"} ->
          Ros2.SensorMsgs.Msg.Imu.parse(payload)
        {:ok, "std_msgs/msg/string"} ->
          Ros2.StdMsgs.Msg.String.parse(payload)
        _ ->
          IO.inspect(topic, label: "Unknown topic")
          :unknown
      end

    Enum.each(state.subscribers, fn {subscribed_topic, pids} ->
      Enum.each(pids, fn pid ->
        case String.starts_with?(topic, subscribed_topic) do
          true -> send(pid, {:mqtt_message, {topic, parsed_message}})
          false -> :noop
        end
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    IO.puts("MQTT client disconnected: #{inspect(reason)}")
    {:stop, reason, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:start_subscriber, topic}, {from, _tag}, state) do
    {:ok, _, _} = :emqtt.subscribe(state.mqtt_pid, [{topic <> "#", 0}])
    subscribers = state.subscribers |> Map.update(topic, [from], fn subs -> subs ++ [from] end)
    {:reply, :ok, %{state | subscribers: subscribers} |> IO.inspect}
  end

  def start_subscriber(topic) do
    GenServer.call(__MODULE__, {:start_subscriber, topic})
  end

  def start_publisher(message_type, topic) do
  end

  defp extract_message_type(topic) do
    parts = String.split(topic, "/")
    # Find the first part that looks like a ROS2 type (contains "::dds_::")
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
