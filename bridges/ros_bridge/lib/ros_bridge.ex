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
  Bridge library that ferries ROS 2 messages (via native Zenoh) to
  the OVCS CAN bus and back. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement `c:ros_bridge_config/0` to
  supply per-deployment knobs (Zenoh broker IP, etc.).

  Host vs. target is handled at compile time: on host we wire
  `BNO085.Dummy` instead of `BNO085.I2C` so the IMU publish path
  still runs end-to-end against a local Zenoh router without
  hardware.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `RosBridge.Config` struct. The
  vehicle module that bundles `RosBridge` in its `bridge_firmwares/0`
  must implement this callback (declared via `@behaviour RosBridge`).

  Mirrors `default_can_mapping/1`: the host arm is for `./ovcs run`
  (e.g. Zenoh broker on the dev box), the target arm for the deployed
  Nerves firmware (broker reachable from the vehicle network).
  """
  @callback ros_bridge_config(:host | :target) :: RosBridge.Config.t()

  # `Mix.target()` MUST be read at module-compile time, not at
  # runtime: on a deployed Nerves device the Mix application isn't
  # loaded the way it is during a build, so `Mix.target()` at runtime
  # silently returns `:host` and the wrong vehicle config arm gets
  # picked. Branching on the compile-time value defines two distinct
  # `children/0` clauses, exactly one of which is in the firmware.
  if Mix.target() == :host do
    @impl OvcsBridge
    # Host: same supervision shape as target, but `BNO085.Dummy`
    # stands in for `BNO085.I2C` so the IMU publish path is
    # exercised end-to-end without an attached sensor. Endpoint
    # defaults to 127.0.0.1; override via `ZENOH_ENDPOINT_IP`.
    def children do
      config = vehicle().ros_bridge_config(:host)

      [
        {RosBridge.ZenohClient, endpoint_ip: config.zenoh_endpoint_ip},
        heartbeat_child(),
        {RosBridge.JoyInterpreter, []},
        {BNO085.Dummy, []},
        {RosBridge.Imu.Adapter, [driver: BNO085.Dummy]},
        {RosBridge.ImuPublisher, [imu_source: RosBridge.Imu.Adapter]}
      ]
    end
  else
    @impl OvcsBridge
    # Target: full bridge — Zenoh client, heartbeat, joy → CAN
    # translator, BNO085 IMU.
    def children do
      config = vehicle().ros_bridge_config(:target)

      [
        {RosBridge.ZenohClient, endpoint_ip: config.zenoh_endpoint_ip},
        heartbeat_child(),
        {RosBridge.JoyInterpreter, []},
        {BNO085.I2C, []},
        {RosBridge.Imu.Adapter, [driver: BNO085.I2C]},
        {RosBridge.ImuPublisher, [imu_source: RosBridge.Imu.Adapter]}
      ]
    end
  end

  defp heartbeat_child do
    {RosBridge.Heartbeat,
     topic: "ovcs_heartbeat",
     message_module: Ros2.StdMsgs.Msg.String,
     interval_ms: 1_000,
     build: fn counter ->
       %Ros2.StdMsgs.Msg.String{
         data: "heartbeat #{counter} @ #{System.system_time(:millisecond)}"
       }
     end}
  end

  # The vehicle module is stamped into Application env by
  # bridges/firmware's runtime.exs (same mechanism vms_core /
  # infotainment_core use). Fetch! rather than get_env so a
  # misconfigured boot fails loudly instead of with a confusing
  # nil.ros_bridge_config/0 UndefinedFunctionError.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
