defmodule OvcsBusGateway.Config do
  @moduledoc """
  Per-vehicle configuration for `OvcsBusGateway`. Vehicles return one of
  these from their `c:OvcsBusGateway.ovcs_bus_gateway_config/1` callback.

    * `:mqtt` — broker `[host: ..., port: ...]` for the MQTT adapter;
      `nil` leaves the adapter off.
    * `:http` — `[port: ...]` for the HTTP/WebSocket adapter; `nil`
      leaves the adapter off.
    * `:forward_interval` — milliseconds between batches the collector
      forwards to the gateway.
  """
  defstruct mqtt: nil, http: [port: 4100], forward_interval: 20

  @type t :: %__MODULE__{
          mqtt: nil | [host: String.t(), port: pos_integer()],
          http: nil | [port: pos_integer()],
          forward_interval: pos_integer()
        }
end
