defmodule RosBridge do
  @moduledoc """
  Bridge library that ferries ROS2 messages (via Zenoh/MQTT) to the
  OVCS CAN bus and back. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Host vs. target is handled at compile time: on host we wire the
  dummy BNO085 and skip the real IMU publisher so the bridge boots
  without I2C hardware.
  """
  @behaviour OvcsBridge

  alias RosBridge.{ImuPublisher, JoyInterpreter}

  if Mix.target() == :host do
    @impl OvcsBridge
    # Host children stay minimal — no Zenoh dispatcher (needs an
    # MQTT broker reachable on localhost) and no JoyInterpreter
    # (needs Zenoh). Run the full ROS stack via `./ovcs build <v>
    # ros` on a real target, or spin up Mosquitto + boot the
    # bridges firmware separately.
    def children, do: []
  else
    @impl OvcsBridge
    def children do
      [
        {BNO085.I2C, []},
        {ZenohMQTTRos2.Dispatcher, []},
        {JoyInterpreter, []},
        {ImuPublisher, [bno085_module: BNO085.I2C]}
      ]
    end
  end

  @impl OvcsBridge
  def relay_messages do
    # RosBridge's inbound (ROS2 → OVCS) and outbound (OVCS → ROS2)
    # flow is CAN-based today. Add bus message names here as the
    # bridge grows to publish/subscribe on OvcsBus (e.g.
    # `:imu_sample`, `:joy_state`).
    []
  end
end
