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
  `RosBridge.Publishers.StereoCamera`, …). The bridge passes the active
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

  # Read at compile time: on a Nerves device `Mix.target()` returns
  # `:host` at runtime, which would pick the wrong config arm.
  @arm if Mix.target() == :host, do: :host, else: :target

  @doc """
  One `:rest_for_one` subtree with `ZenohClient` first. Consumers
  subscribe only from `init/1`, so they must restart with the client
  to get their subscriptions back.
  """
  @impl OvcsBridge
  def children do
    config = resolve_config()

    core_children = [{RosBridge.ZenohClient, zenoh_client_opts(config)}, RosBridge.Parameters]
    component_children = Enum.flat_map(config.components, &resolve_component/1)

    [
      %{
        id: RosBridge.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             core_children ++ component_children,
             [strategy: :rest_for_one, name: RosBridge.Supervisor]
           ]}
      }
    ]
  end

  # Omit `:node_name` when unset so `ZenohClient` applies its default.
  defp zenoh_client_opts(%RosBridge.Config{node_name: nil} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip]

  defp zenoh_client_opts(%RosBridge.Config{} = config),
    do: [endpoint_ip: config.zenoh_endpoint_ip, node_name: config.node_name]

  defp resolve_config do
    vehicle_module = vehicle()

    cond do
      function_exported?(vehicle_module, :ros_bridge_config, 2) ->
        vehicle_module.ros_bridge_config(@arm, firmware_id())

      function_exported?(vehicle_module, :ros_bridge_config, 1) ->
        vehicle_module.ros_bridge_config(@arm)

      true ->
        raise """
        #{inspect(vehicle_module)} bundles RosBridge in bridge_firmwares/0 but \
        implements neither ros_bridge_config/1 nor ros_bridge_config/2.
        """
    end
  end

  # Env first: on host every bridge role shares one build and `./ovcs run` sets the id per BEAM.
  defp firmware_id do
    System.get_env("BRIDGE_FIRMWARE_ID") ||
      Application.get_env(:ovcs_bridge, :firmware_id, "ros")
  end

  defp resolve_component(name) when is_atom(name), do: RosBridge.Components.start(name, [])

  defp resolve_component({name, opts}) when is_atom(name),
    do: RosBridge.Components.start(name, opts)

  # Set by bridges/firmware's runtime.exs; fetch! so a misconfigured boot fails loudly.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
