defmodule RadioControlBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `RadioControlBridge`. Vehicles return
  one of these from their `c:RadioControlBridge.radio_control_bridge_config/1`
  callback.

  One knob:

    * `:components` — the list of `radio_control_bridge` features
      the vehicle wants. Each entry is either a bare component atom
      (`:msp_osd_forwarder`) or a `{name, opts}` tuple
      (`{:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}`).
      See `RadioControlBridge.Components` for the catalogue. UART
      pins / baud rates live in each component's opts so two
      forwarders that talk to different hardware paths (ExpressLRS
      receiver vs. MSP DisplayPort to a VTX) don't fight over a
      single shared field.
  """
  defstruct components: []

  @type component :: atom() | {atom(), keyword()}
  @type t :: %__MODULE__{components: [component()]}

  @doc """
  Returns the opts keyword list for `component` in this config, or
  `nil` if the component isn't listed. Bare atoms return `[]`.

  Useful for code that needs to inspect per-component opts before
  the supervision tree starts — e.g. `bridges/firmware`'s
  `runtime.exs` reading the MAVLink UART pin to stamp `:express_lrs`
  env before `ExpressLrs.Application` boots.
  """
  def component_opts(%__MODULE__{components: components}, name) when is_atom(name) do
    Enum.find_value(components, fn
      ^name -> []
      {^name, opts} -> opts
      _ -> nil
    end)
  end
end

defmodule RadioControlBridge do
  @moduledoc """
  Bridge library that forwards ExpressLRS MAVLink RC channels onto
  the vehicle's OVCS CAN bus and (eventually) pushes vehicle
  telemetry back out as MSP DisplayPort to a VTX. Hosted by the
  shared `bridges/firmware` Nerves image; vehicles opt in via their
  `bridge_firmwares/0` map.

  Vehicles implement `c:radio_control_bridge_config/1` to declare
  which components run. UART pins and baud rates live in each
  component's opts — `:mavlink_forwarder` carries the ExpressLRS
  UART, and `:msp_osd_forwarder` will carry the MSP DisplayPort
  UART when it's implemented. The bridge firmware's `runtime.exs`
  reads each component's opts in turn to stamp the matching
  third-party app env (`:express_lrs`, `:msp_osd`, …) before
  applications start.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `RadioControlBridge.Config` struct.
  Declared via `@behaviour RadioControlBridge` on the vehicle module
  that bundles this bridge.

  The arm tag (`:host` for `./ovcs run`, `:target` for the deployed
  Nerves firmware) lets the vehicle return a different component
  list per environment — typically `components: []` on host (no
  UART hardware) and an enabled forwarder on target.
  """
  @callback radio_control_bridge_config(:host | :target) :: RadioControlBridge.Config.t()

  # `Mix.target()` MUST be read at module-compile time, not at
  # runtime: on a deployed Nerves device the Mix application isn't
  # loaded the way it is during a build, so `Mix.target()` at runtime
  # silently returns `:host` and the wrong vehicle config arm gets
  # picked. Branching on the compile-time value bakes the arm in.
  @arm if Mix.target() == :host, do: :host, else: :target

  @impl OvcsBridge
  def children do
    config = vehicle().radio_control_bridge_config(@arm)
    Enum.flat_map(config.components, &resolve_component/1)
  end

  defp resolve_component(name) when is_atom(name),
    do: RadioControlBridge.Components.start(name, [])

  defp resolve_component({name, opts}) when is_atom(name),
    do: RadioControlBridge.Components.start(name, opts)

  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
