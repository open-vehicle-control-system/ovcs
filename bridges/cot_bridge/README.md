# cot_bridge

Elixir bridge between the OVCS bus and a [TAK](https://tak.gov)
server, publishing the vehicle position as Cursor on Target (CoT)
events so the vehicle can be followed live from WebTAK / ATAK clients
outside the vehicle. Hosted by `bridges/firmware`; vehicles opt in
via `bridge_firmwares/0`.

## Layout

```
lib/
  cot_bridge.ex                # OvcsBridge behaviour + Config + child list (host / target)
  cot_bridge/
    position_tracker.ex        # OvcsBus :vehicle_position consumer → latest-position cache
    cot.ex                     # Pure CoT <event> XML rendering (unit-tested)
    publisher.ex               # Periodic tick: latest position → Cot → TakConnection
    tak_connection.ex          # tcp / udp / tls socket to the TAK server, reconnect loop
```

## Data flow

```
OvcsBus "messages" ──▶ PositionTracker ──▶ Publisher ──▶ TakConnection ──▶ TAK server ──▶ WebTAK
  :vehicle_position       (cache)          (CoT XML)      (tcp/udp/tls)
```

The bridge never touches CAN itself: it consumes the
`:vehicle_position` message that the VMS broadcasts on `OvcsBus`,
whichever component produced it. Today that's
`VmsCore.Components.OVCS.Gnss` decoding the `gnss_position` /
`gnss_status` CAN frames; a component fetching the position from
another device over Ethernet just has to broadcast the same message
shape:

```elixir
%OvcsBus.Message{
  name: :vehicle_position,
  value: %{
    latitude: Decimal,          # decimal degrees, WGS84
    longitude: Decimal,         # decimal degrees, WGS84
    altitude: Decimal | nil,    # metres
    speed: Decimal | nil,       # km/h
    heading: Decimal | nil,     # degrees, true north
    fix_type: atom,             # :fix_2d | :fix_3d | :dgnss
    satellite_count: integer,
    timestamp: DateTime
  },
  source: module
}
```

## Configuration

Vehicles that bundle this bridge implement
`c:CotBridge.cot_bridge_config/1`, returning a `CotBridge.Config`
naming the TAK endpoint plus optional identity / cadence overrides —
see the `CotBridge.Config` moduledoc for every knob. Example (from
`Ovcs1`):

```elixir
@impl CotBridge
def cot_bridge_config(:host),
  do: %CotBridge.Config{
    tak_host: System.get_env("TAK_SERVER_HOST", "127.0.0.1"),
    tak_port: "TAK_SERVER_PORT" |> System.get_env("8087") |> String.to_integer()
  }
```

The default identity places a friendly ground-vehicle marker
(`a-f-G-E-V-C`) named after the vehicle; connection protocols are
`:tcp` (TAK streaming input, port 8087), `:udp`, or `:tls` (port
8089 — pass client certificates via `:ssl_options`).

## Trying it end-to-end on a host

1. Run a TAK server reachable from your machine (e.g.
   [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer) or
   [taky](https://github.com/tkuester/taky) for a quick local CoT
   endpoint) and open WebTAK against it.
2. Boot the vehicle: `TAK_SERVER_HOST=<server-ip> ./ovcs run ovcs1`.
3. Feed a GNSS fix onto the vcan bus (Brussels, 30 km/h heading east,
   3D fix with 12 satellites):

   ```sh
   cansend vcan0 620#D8234F1E48049802   # lat 50.8503000°, lon 4.3517000°
   cansend vcan0 621#3002B80B28230C40   # alt 56.0m, 30 km/h, 90°, 12 sats, fix_3d
   ```

The `OVCS1` marker appears on the WebTAK map within a publish tick
and goes stale ~20s after the frames stop (replay a candump for a
moving target).
