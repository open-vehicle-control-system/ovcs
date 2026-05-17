defmodule RadioControlBridge.Components do
  @moduledoc """
  Resolves the symbolic component entries in a vehicle's
  `RadioControlBridge.Config.components` list into supervised child
  specs.

  Each clause of `start/2` returns a list of one or more child specs
  for the named component. Vehicles compose `radio_control_bridge`
  by listing the components they want; adding a new feature is one
  new clause here plus one opt-in line per vehicle that wants it.

  ## Components today

    * `:mavlink_forwarder` — `RadioControlBridge.MavlinkForwarder`,
      the ExpressLRS MAVLink RC-channel → CAN bus path. Opts:
        * `:uart_port` (required), `:uart_baud_rate` (required) —
          the UART the ExpressLRS receiver is wired to. Read out of
          the component opts by `bridges/firmware`'s `runtime.exs`
          to stamp `:express_lrs` Application env *before*
          `ExpressLrs.Application` boots, since the connector reads
          its UART config once at startup. Not consumed by the
          forwarder GenServer itself.

    * `:msp_osd_forwarder` — `RadioControlBridge.MspOsdForwarder`,
      placeholder for the vehicle-metrics → MSP DisplayPort path.
      No opts today; when the forwarder gains real behaviour it'll
      carry its own `:uart_port` / `:uart_baud_rate` opts for the
      VTX serial line (different hardware path than the ExpressLRS
      receiver, hence per-component UART config rather than a
      shared field on `RadioControlBridge.Config`).
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises
  on unknown names so a typo in a vehicle's `:components` list
  fails loudly at boot.
  """
  def start(:mavlink_forwarder, _opts), do: [{RadioControlBridge.MavlinkForwarder, nil}]

  def start(:msp_osd_forwarder, _opts), do: [{RadioControlBridge.MspOsdForwarder, nil}]
end
