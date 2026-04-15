defmodule OvcsBus.Relay do
  @moduledoc """
  Pluggable relays that mirror specific `OvcsBus.Message` names to/from
  an off-node transport, letting each firmware's local bus talk to peer
  buses over the vehicle LAN.

  Each relay runs as a supervised GenServer added to the consumer's
  supervision tree (typically by the firmware's `Application` or a
  vehicle composer). Today:

  - `OvcsBus.Relay.Mqtt` — mirrors via MQTT (`:emqtt`).

  A relay tags inbound messages with `:relay_origin` (e.g. `:mqtt`) so
  the outbound path can skip messages it just injected, avoiding echo
  loops.
  """
end
