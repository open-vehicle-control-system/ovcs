defmodule RadioControlBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `RadioControlBridge`. Vehicles return
  one of these from their `c:RadioControlBridge.radio_control_bridge_config/0`
  callback. Drives the `:express_lrs` UART connector.
  """
  @enforce_keys [:uart_port, :uart_baud_rate]
  defstruct [:uart_port, :uart_baud_rate]

  @type t :: %__MODULE__{uart_port: String.t(), uart_baud_rate: pos_integer()}
end

defmodule RadioControlBridge do
  @moduledoc """
  Bridge library that forwards ExpressLRS MAVLink RC channels onto
  the vehicle's OVCS CAN bus. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.

  Vehicles that bundle this bridge implement `c:radio_control_bridge_config/0`
  to point at the UART their ExpressLRS receiver is wired to. The
  bridges firmware's `runtime.exs` reads it and stamps `:express_lrs`
  config before applications start, so `ExpressLrs.Mavlink.Connector`
  opens the right device at boot.
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `RadioControlBridge.Config` struct.
  Declared via `@behaviour RadioControlBridge` on the vehicle module
  that bundles this bridge.

  Mirrors `default_can_mapping/1`: the host arm is for `./ovcs run`
  (USB-UART dev adapter), the target arm for the deployed Nerves
  firmware (Pi UART pin).
  """
  @callback radio_control_bridge_config(:host | :target) :: RadioControlBridge.Config.t()

  if Mix.target() == :host do
    @impl OvcsBridge
    # MavlinkForwarder needs an ExpressLRS UART to register with,
    # which isn't available when running in a host BEAM (e.g.
    # `cd vehicles/<v> && iex -S mix`). Return no children so the
    # bridge stays dormant locally; the full flow runs on-target.
    def children, do: []
  else
    @impl OvcsBridge
    def children do
      [
        {RadioControlBridge.MavlinkForwarder, nil}
      ]
    end
  end
end
