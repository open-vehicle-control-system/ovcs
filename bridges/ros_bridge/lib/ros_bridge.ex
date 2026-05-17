defmodule RosBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `RosBridge`. Vehicles return one of
  these from their `c:RosBridge.ros_bridge_config/1` callback.

  Two knobs:

    * `:zenoh_endpoint_ip` — the Zenoh router this bridge peers with.
    * `:components` — the list of `ros_bridge` features the vehicle
      wants on top of the always-on `ZenohClient`. Each entry is
      either a bare component atom (`:heartbeat`) or a `{name, opts}`
      tuple (`{:imu_publisher, driver: BNO085.I2C}`). See
      `RosBridge.Components` for the catalogue.
  """
  @enforce_keys [:zenoh_endpoint_ip]
  defstruct [:zenoh_endpoint_ip, components: []]

  @type component :: atom() | {atom(), keyword()}
  @type t :: %__MODULE__{
          zenoh_endpoint_ip: String.t(),
          components: [component()]
        }
end

defmodule RosBridge do
  @moduledoc """
  Bridge library that ferries ROS 2 messages (via native Zenoh) to
  the OVCS CAN bus and back. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement `c:ros_bridge_config/1`,
  returning a `RosBridge.Config` that names the Zenoh router and the
  list of components to start (`RosBridge.Heartbeat`,
  `RosBridge.JoyInterpreter`, `RosBridge.ImuPublisher`, …). The
  bridge passes the active `:host`/`:target` arm so the vehicle can
  pick different drivers / endpoints / opts per environment.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `RosBridge.Config` struct. The
  vehicle module that bundles `RosBridge` in its `bridge_firmwares/0`
  must implement this callback (declared via `@behaviour RosBridge`).

  The arm tag (`:host` for `./ovcs run`, `:target` for the deployed
  Nerves firmware) lets the vehicle return a different component
  list / driver mix per environment — e.g. `OvcsDrivers.Imu.Dummy`
  on host, `BNO085.I2C` on target.
  """
  @callback ros_bridge_config(:host | :target) :: RosBridge.Config.t()

  # `Mix.target()` MUST be read at module-compile time, not at
  # runtime: on a deployed Nerves device the Mix application isn't
  # loaded the way it is during a build, so `Mix.target()` at runtime
  # silently returns `:host` and the wrong vehicle config arm gets
  # picked. Branching on the compile-time value bakes the arm in.
  @arm if Mix.target() == :host, do: :host, else: :target

  @impl OvcsBridge
  def children do
    config = vehicle().ros_bridge_config(@arm)

    base = [{RosBridge.ZenohClient, endpoint_ip: config.zenoh_endpoint_ip}]
    extras = Enum.flat_map(config.components, &resolve_component/1)

    base ++ extras
  end

  defp resolve_component(name) when is_atom(name), do: RosBridge.Components.start(name, [])
  defp resolve_component({name, opts}) when is_atom(name), do: RosBridge.Components.start(name, opts)

  # The vehicle module is stamped into Application env by
  # bridges/firmware's runtime.exs (same mechanism vms_core /
  # infotainment_core use). Fetch! rather than get_env so a
  # misconfigured boot fails loudly instead of with a confusing
  # nil.ros_bridge_config/1 UndefinedFunctionError.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
