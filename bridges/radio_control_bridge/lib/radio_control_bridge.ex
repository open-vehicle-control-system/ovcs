defmodule RadioControlBridge do
  @moduledoc """
  Bridge library that forwards ExpressLRS MAVLink RC channels onto
  the vehicle's OVCS CAN bus. Hosted by the shared `bridges/firmware`
  Nerves image; vehicles opt in via their `bridge_firmwares/0` map.
  """
  @behaviour OvcsBridge

  alias RadioControlBridge.MavlinkForwarder

  @impl OvcsBridge
  def children do
    [
      {MavlinkForwarder, nil}
    ]
  end

  @impl OvcsBridge
  def relay_messages do
    # RadioControlBridge's work is CAN-only today (it emits the two
    # radio_control_channels frames via Cantastic); no bus messages
    # cross a relay yet. List names here as the bridge grows to use
    # OvcsBus (e.g. `:rc_link_state`, `:failsafe_active`).
    []
  end
end
