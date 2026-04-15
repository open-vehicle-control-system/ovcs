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
end
