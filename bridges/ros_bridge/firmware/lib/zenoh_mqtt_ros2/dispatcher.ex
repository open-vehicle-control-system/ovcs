defmodule ZenohMQTTRos2.Dispatcher do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def extract_msg_type(topic) do
    # Split by slash
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


  @impl true
  def init(_opts) do
    client_id = "elixir_subscriber_#{:rand.uniform(1000)}"
    host = "172.16.0.63"
    port = 1883

    {:ok, pid} = :emqtt.start_link([
      {:host, host},
      {:port, port},
      {:clientid, client_id},
      {:clean_start, true}
    ])

    case :emqtt.connect(pid) do
      {:ok, _} ->
        IO.puts("Connected to MQTT broker")

        {:ok, _, _} = :emqtt.subscribe(pid, [{"#", 0}])
        IO.puts("Subscribed to all topics: #")

        Process.monitor(pid)

        {:ok, %{mqtt_pid: pid}}

      {:error, reason} ->
        IO.puts("Failed to connect: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:publish, %{topic: topic, payload: payload}}, state) do
    IO.puts("Received on topic: #{topic}")

    result =
      case extract_msg_type(topic) |> IO.inspect do
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

    IO.inspect(result, label: "Parsed message")

    {:noreply, state}
  end

  # Handle MQTT client down
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    IO.puts("MQTT client disconnected: #{inspect(reason)}")
    {:stop, reason, state}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  def start_subscriber(message_type, topic) do

  end

  def start_publisher(message_type, topic) do

  end
end
