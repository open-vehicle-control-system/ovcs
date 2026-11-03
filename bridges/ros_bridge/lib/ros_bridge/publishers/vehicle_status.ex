defmodule RosBridge.Publishers.VehicleStatus do
  @moduledoc """
  The VMS's state for the operator's displays: one topic per signal
  under `:topic_prefix` (`vehicle`), from three CAN frames.

  | Topic | Type | Frame |
  |---|---|---|
  | `vms_status` | `std_msgs/String` | `vms_status` (`0x1A0`) |
  | `ready_to_drive` | `std_msgs/Bool` | `vms_status` (`0x1A0`) |
  | `gear` | `std_msgs/String` | `gear_status` (`0x600`) |
  | `control_level` | `std_msgs/String` | `control_status` (`0x60C`) |
  | `ros_commander` | `std_msgs/String` | `control_status` (`0x60C`) |
  | `control_level_forced` | `std_msgs/Bool` | `control_status` (`0x60C`) |
  | `requested_throttle` | `std_msgs/Float64` | `control_status` (`0x60C`) |
  | `requested_steering` | `std_msgs/Float64` | `control_status` (`0x60C`) |

  A frame the vehicle's bridge topology does not receive is skipped,
  with a log line, and its topics stay silent. Every frame received is
  published, retransmissions included: the frames carry no sequence,
  and a display fed at the frame's rate shows when the VMS goes quiet.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias Ros2Zenoh.StdMsgs.Msg.{Bool, Float64}
  alias Ros2Zenoh.StdMsgs.Msg.String, as: RosString

  require Logger

  @frame_names ["vms_status", "gear_status", "control_status"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, "vehicle")

    Enum.each(@frame_names, fn frame_name ->
      case Receiver.subscribe(self(), :ovcs, frame_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.info("#{__MODULE__} skips #{frame_name}: #{inspect(reason)}")
      end
    end)

    Logger.info("#{__MODULE__} publishing on #{topic_prefix}/*")
    {:ok, %{topic_prefix: topic_prefix}}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) do
    name
    |> messages(signals)
    |> Enum.each(fn {topic, message_module, message} ->
      RosBridge.ZenohClient.publish("#{state.topic_prefix}/#{topic}", message_module, message)
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "The `{topic, message_module, message}` a frame's signals publish."
  def messages("vms_status", signals) do
    [
      {"vms_status", RosString, %RosString{data: "#{value(signals, "status")}"}},
      {"ready_to_drive", Bool, %Bool{data: value(signals, "ready_to_drive") == true}}
    ]
  end

  def messages("gear_status", signals) do
    [{"gear", RosString, %RosString{data: "#{value(signals, "selected_gear")}"}}]
  end

  def messages("control_status", signals) do
    [
      {"control_level", RosString, %RosString{data: "#{value(signals, "control_level")}"}},
      {"ros_commander", RosString, %RosString{data: "#{value(signals, "ros_commander")}"}},
      {"control_level_forced", Bool, %Bool{data: value(signals, "control_level_forced") == true}},
      {"requested_throttle", Float64,
       %Float64{data: Decimal.to_float(value(signals, "requested_throttle"))}},
      {"requested_steering", Float64,
       %Float64{data: Decimal.to_float(value(signals, "requested_steering"))}}
    ]
  end

  def messages(_frame_name, _signals), do: []

  defp value(signals, name) do
    %Signal{value: signal_value} = Map.fetch!(signals, name)
    signal_value
  end
end
