defmodule RosBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `RosBridge`. Vehicles return one of these
  from their `c:RosBridge.ros_config/0` callback.
  """
  @enforce_keys [:zenoh_endpoint_ip]
  defstruct [:zenoh_endpoint_ip]

  @type t :: %__MODULE__{zenoh_endpoint_ip: String.t()}
end

defmodule RosBridge do
  @moduledoc """
  Bridge library that ferries ROS2 messages (via Zenoh/MQTT) to the
  OVCS CAN bus and back. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement `c:ros_bridge_config/0` to
  supply per-deployment knobs (Zenoh broker IP, etc.).

  Host vs. target is handled at compile time: on host we wire the
  dummy BNO085 and skip the real IMU publisher so the bridge boots
  without I2C hardware.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `RosBridge.Config` struct. The
  vehicle module that bundles `RosBridge` in its `bridge_firmwares/0`
  must implement this callback (declared via `@behaviour RosBridge`).
  """
  @callback ros_bridge_config() :: RosBridge.Config.t()

  if Mix.target() == :host do
    @impl OvcsBridge
    # Host children stay minimal — no Zenoh dispatcher (needs an
    # MQTT broker reachable on localhost) and no JoyInterpreter
    # (needs Zenoh). Run the full ROS stack via `./ovcs build <v>
    # bridge-ros` on a real target, or spin up Mosquitto + boot the
    # bridges firmware separately.
    def children, do: []
  else
    @impl OvcsBridge
    def children do
      cfg = vehicle().ros_bridge_config()

      [
        {BNO085.I2C, []},
        {ZenohMQTTRos2.Dispatcher, endpoint_ip: cfg.zenoh_endpoint_ip},
        {RosBridge.JoyInterpreter, []},
        {RosBridge.ImuPublisher, [bno085_module: BNO085.I2C]}
      ]
    end

    # The vehicle module is stamped into Application env by
    # bridges/firmware's runtime.exs (same mechanism vms_core /
    # infotainment_core use). Fetch! rather than get_env so a
    # misconfigured boot fails loudly instead of with a confusing
    # nil.ros_bridge_config/0 UndefinedFunctionError.
    defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
  end
end
