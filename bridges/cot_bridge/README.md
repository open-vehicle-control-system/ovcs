# cot_bridge

Elixir bridge between the OVCS bus and a [TAK](https://tak.gov)
server, publishing the vehicle position as Cursor on Target (CoT)
events so the vehicle can be followed live from WebTAK / ATAK clients
outside the vehicle. Hosted by `bridges/firmware`; vehicles opt in
via `bridge_firmwares/0`.

## Layout

```
lib/
  cot_bridge.ex                        # OvcsBridge behaviour + Config + child list (host / target)
  cot_bridge/
    position_tracker.ex                # Combines position/altitude/speed/heading per *_source knobs
    cot.ex                             # CoT <event> assigns preparation + XML escaping (unit-tested)
    cot/position_event.xml.eex         # The CoT event document shape (EEx, compiled in)
    publisher.ex                       # Periodic tick: latest position → Cot → TakConnection
    tak_connection.ex                  # tcp / udp / tls socket to the TAK server, reconnect loop
```

## Data flow

```
OvcsBus "messages"  ──▶ PositionTracker ──▶ Publisher ──▶ TakConnection ──▶ TAK server ──▶ WebTAK
  :vehicle_position     (combine per        (CoT XML)      (tcp/udp/tls)
  :altitude :speed       *_source knobs)
  :heading
```

The bridge never touches CAN itself and owns no data: every CoT
parameter is combined from the bus messages of whichever component
the vehicle names for it, following the composers' source-module
convention. No parameter has a guaranteed owner — a GNSS receiver
may or may not report altitude or a usable course, speed usually
belongs to the ABS/drivetrain driver, a compass/IMU component could
own the heading:

| Parameter | Bus message | Config knob | OVCS1 source |
|-----------|-------------|-------------|--------------|
| position | `:vehicle_position` | `:position_source` | `OVCS.Gnss` |
| altitude (m) | `:altitude` | `:altitude_source` | `OVCS.Gnss` |
| speed (km/h) | `:speed` | `:speed_source` | `Polo9N.ABS` |
| heading (°) | `:heading` | `:heading_source` | `OVCS.Gnss` (course over ground) |

A knob left `nil` renders that parameter as unknown; without a fresh
position nothing is published at all. `:vehicle_position` is the one
composite message (half a coordinate is meaningless):

```elixir
%OvcsBus.Message{
  name: :vehicle_position,
  value: %{
    latitude: Decimal,          # decimal degrees, WGS84
    longitude: Decimal,         # decimal degrees, WGS84
    fix_type: atom,             # :fix_2d | :fix_3d | :dgnss
    satellite_count: integer,
    timestamp: DateTime
  },
  source: module
}
```

Any component broadcasting these messages can feed the bridge — the
CAN GNSS receiver, a position fetched from another device (a phone,
say) over Ethernet, a barometric altitude. Mind that a GNSS
`:heading` is a course over ground derived from movement, not a
compass heading: it's only meaningful while driving, which is fine
for tracking a vehicle. Point `:heading_source` at a
magnetometer/IMU component if standstill orientation matters.

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
    tak_port: "TAK_SERVER_PORT" |> System.get_env("8087") |> String.to_integer(),
    position_source: OVCS.Gnss,
    altitude_source: OVCS.Gnss,
    heading_source: OVCS.Gnss,
    speed_source: Polo9N.ABS
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
3. Feed a GNSS fix onto the vcan bus (Brussels, heading east, 3D fix
   with 12 satellites):

   ```sh
   cansend vcan0 620#D8234F1E48049802   # lat 50.8503000°, lon 4.3517000°
   cansend vcan0 621#300228230C40       # alt 56.0m, heading 90°, 12 sats, fix_3d
   ```

The `OVCS1` marker appears on the WebTAK map within a publish tick
and goes stale ~20s after the frames stop (replay a candump for a
moving target). The track speed rides along as soon as the vehicle's
speed source broadcasts (`Polo9N.ABS` on OVCS1, fed by the polo_drive
bus) and shows as unknown otherwise.
