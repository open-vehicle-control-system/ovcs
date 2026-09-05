defmodule RosBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `RosBridge`. Vehicles return one of
  these from their `c:RosBridge.ros_bridge_config/1` callback.

  Three knobs:

    * `:zenoh_endpoint_ip` — the Zenoh router this bridge peers with.
    * `:components` — the list of `ros_bridge` features the vehicle
      wants on top of the always-on `ZenohClient`. Each entry is
      either a bare component atom (`:heartbeat`) or a `{name, opts}`
      tuple (`{:imu_publisher, driver: BNO085.I2C}`). See
      `RosBridge.Components` for the catalogue.
    * `:node_name` — the ROS 2 node name this bridge announces in its
      rmw_zenoh liveliness tokens. Defaults to `ZenohClient`'s
      `"ovcs_bridge"`. Set it per firmware whenever a vehicle runs
      more than one ROS bridge on the same fabric: two bridges sharing
      a name collide in the ROS graph, and `ros2 node list` warns about
      it while Foxglove merges them into one entry.
  """
  @enforce_keys [:zenoh_endpoint_ip]
  defstruct [:zenoh_endpoint_ip, :node_name, components: []]

  @type component :: atom() | {atom(), keyword()}
  @type t :: %__MODULE__{
          zenoh_endpoint_ip: String.t(),
          node_name: String.t() | nil,
          components: [component()]
        }
end

defmodule RosBridge do
  @moduledoc """
  Bridge library that ferries ROS 2 messages (via native Zenoh) to
  the OVCS CAN bus and back. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement either
  `c:ros_bridge_config/1` or `c:ros_bridge_config/2`, returning a
  `RosBridge.Config` that names the Zenoh router and the list of
  components to start (`RosBridge.Publishers.Heartbeat`,
  `RosBridge.Consumers.Joy`, `RosBridge.Publishers.Imu`,
  `RosBridge.Publishers.Camera`, …). The bridge passes the active
  `:host`/`:target` arm and the bridge firmware id, so vehicles
  running this bridge on more than one physical device (e.g. an IMU
  bridge on a Pi 4 alongside a perception bridge on a Pi 5) can
  return a different component list per deployment.

  Vehicles with a single ROS bridge can ignore the firmware id and
  keep implementing `ros_bridge_config/1`.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config, ignoring which `bridge_firmwares/0` entry
  is active. Most vehicles want this arity — only implement `/2` if
  the same vehicle deploys `RosBridge` to more than one physical
  device with diverging component lists.
  """
  @callback ros_bridge_config(arm :: :host | :target) :: RosBridge.Config.t()

  @doc """
  Per-deployment config that also takes the `bridge_firmwares/0`
  entry id (e.g. `"ros"`, `"ros_perception"`), letting a single
  vehicle return a different `RosBridge.Config` per bridge BEAM.
  """
  @callback ros_bridge_config(
              arm :: :host | :target,
              firmware_id :: String.t()
            ) :: RosBridge.Config.t()

  @optional_callbacks ros_bridge_config: 1, ros_bridge_config: 2

  # `Mix.target()` MUST be read at module-compile time, not at
  # runtime: on a deployed Nerves device the Mix application isn't
  # loaded the way it is during a build, so `Mix.target()` at runtime
  # silently returns `:host` and the wrong vehicle config arm gets
  # picked. Branching on the compile-time value bakes the arm in.
  @arm if Mix.target() == :host, do: :host, else: :target

  # One `:rest_for_one` subtree with `ZenohClient` first. Consumers
  # subscribe from `init/1` and never again, so a client that restarts
  # alone comes back with an empty subscription map and every consumer
  # is deaf until the BEAM restarts. Restarting everything after it is
  # what makes a client crash recoverable. Publishers would survive
  # either way (they re-declare lazily), but a consistent restart is
  # simpler to reason about than a partial one.
  @impl OvcsBridge
  def children do
    config = resolve_config()

    base = [{RosBridge.ZenohClient, zenoh_client_opts(config)}]
    extras = Enum.flat_map(config.components, &resolve_component/1)

    [
      %{
        id: RosBridge.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [base ++ extras, [strategy: :rest_for_one, name: RosBridge.Supervisor]]}
      }
    ]
  end

  # `:node_name` is optional — omit the key entirely when the vehicle
  # leaves it unset so `ZenohClient` applies its own default rather
  # than receiving an explicit nil.
  defp zenoh_client_opts(%RosBridge.Config{node_name: nil} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip]

  defp zenoh_client_opts(%RosBridge.Config{} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip, node_name: config.node_name]

  defp resolve_config do
    mod = vehicle()

    cond do
      function_exported?(mod, :ros_bridge_config, 2) ->
        mod.ros_bridge_config(@arm, firmware_id())

      function_exported?(mod, :ros_bridge_config, 1) ->
        mod.ros_bridge_config(@arm)

      true ->
        raise """
        #{inspect(mod)} bundles RosBridge in bridge_firmwares/0 but \
        implements neither ros_bridge_config/1 nor ros_bridge_config/2.
        """
    end
  end

  # `BRIDGE_FIRMWARE_ID` first, mirroring `OvcsBridge.Supervisor`: on
  # host every bridge role shares one compiled build, whose config
  # bakes "radio_control" (bridges/firmware/config/config.exs), and
  # `./ovcs run` sets the real id per BEAM. Reading only the compiled
  # value made the perception BEAM resolve "radio_control" and start
  # joy/IMU instead of the stereo pipeline. On target the env isn't
  # present and the per-firmware baked value is correct; the "ros"
  # default preserves the historical single-bridge behaviour.
  defp firmware_id do
    System.get_env("BRIDGE_FIRMWARE_ID") ||
      Application.get_env(:ovcs_bridge, :firmware_id, "ros")
  end

  defp resolve_component(name) when is_atom(name), do: RosBridge.Components.start(name, [])

  defp resolve_component({name, opts}) when is_atom(name),
    do: RosBridge.Components.start(name, opts)

  # The vehicle module is stamped into Application env by
  # bridges/firmware's runtime.exs (same mechanism vms_core /
  # infotainment_core use). Fetch! rather than get_env so a
  # misconfigured boot fails loudly instead of with a confusing
  # nil.ros_bridge_config/1 UndefinedFunctionError.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
