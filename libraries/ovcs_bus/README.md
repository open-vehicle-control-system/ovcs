# OvcsBus

Node-local pub/sub bus shared across the VMS, infotainment, and
bridge firmwares. Thin wrapper around `Phoenix.PubSub`, plus an
opt-in MQTT relay that lets each firmware's local bus talk to peer
buses across the vehicle LAN.

## Why

Components (`VmsCore.Components.*`, managers, bridges, …) need a
decoupled way to publish intent + state without wiring GenServer
calls between each other. OvcsBus is that decoupling layer. Every
firmware that depends on `ovcs_bus` gets the registry started
automatically — no per-consumer supervision wiring.

## Local API

```elixir
OvcsBus.subscribe("messages")

OvcsBus.broadcast(
  "messages",
  %OvcsBus.Message{name: :ready_to_drive, value: true, source: __MODULE__}
)
```

Convention across OVCS firmwares: a single topic `"messages"` is
used and subscribers discriminate in `handle_info` using the
`%OvcsBus.Message{}` struct's `:name` + `:source` fields. Topics
are free-form strings — add more if you need fan-out isolation.

`OvcsBus.Message`:
- `:name`          — short atom (e.g. `:ready_to_drive`, `:speed`).
- `:value`         — arbitrary payload.
- `:source`        — publishing module, used to disambiguate when
  several components publish the same name.
- `:relay_origin`  — `nil` for locally-published messages; set by
  a relay (e.g. `:mqtt`) when a message arrives from a peer bus.
  Outbound relays use it to avoid echo loops.

## Cross-firmware relay (MQTT)

`OvcsBus.Relay.Mqtt` mirrors selected messages between the local
bus and an MQTT broker so multiple firmwares on the vehicle LAN
share one logical bus.

Opts (map or keyword list):

```elixir
{OvcsBus.Relay.Mqtt,
 broker: [host: "ovcs1-vms.local", port: 1884, username: "…", password: "…"],
 client_id: "ovcs1-vms",
 topic_prefix: "ovcs/ovcs1/bus",
 topics: [:ready_to_drive, :vms_status]}
```

Each bus message name `X` maps to MQTT topic `<topic_prefix>/<X>`.
Messages are serialised with `:erlang.term_to_binary/1` and decoded
with `[:safe]`. Inbound messages are re-broadcast locally with
`:relay_origin` set, so the outbound side skips them.

Who starts the relay:
- **VMS** — `VmsCore.Application` starts it when the vehicle's VMS
  composer implements `bus_relay/0`.
- **Infotainment** — same via `InfotainmentCore.Application`.
- **Bridges** — `OvcsBridge.Supervisor` reads `:bus_relay` from the
  vehicle's `bridge_firmwares/0` entry and merges topics from each
  bundled bridge's `relay_messages/0`.

### How nodes actually connect

There is **no direct node-to-node link** between OVCS firmwares —
no Erlang distribution, no cookies to align, no cluster to join.
Each firmware is an independent MQTT client; the broker is the
hub. Topology on a vehicle running all three sides:

```
┌─────────────────────┐       ┌───────────────────────┐       ┌──────────────────────────┐
│ VMS firmware        │       │ MQTT broker           │       │ Infotainment firmware    │
│ ┌─────────────────┐ │       │ (Mosquitto / EMQX,    │       │ ┌──────────────────────┐ │
│ │ OvcsBus (local) │ │       │  hosted on the VMS    │       │ │ OvcsBus (local)      │ │
│ │   ↕             │ │ MQTT  │  box by convention)   │ MQTT  │ │   ↕                  │ │
│ │ Relay.Mqtt ◄────┼─┼──────►│                       │◄──────┼─┤ Relay.Mqtt           │ │
│ └─────────────────┘ │       └─────────┬─────────────┘       │ └──────────────────────┘ │
└─────────────────────┘                 │                     └──────────────────────────┘
                                        │ MQTT
                                        ▼
                             ┌─────────────────────────────┐
                             │ Bridge firmware (any SoC)   │
                             │ ┌──────────────────────┐    │
                             │ │ OvcsBus (local)      │    │
                             │ │   ↕                  │    │
                             │ │ Relay.Mqtt           │    │
                             │ └──────────────────────┘    │
                             └─────────────────────────────┘
```

Each `OvcsBus.Relay.Mqtt` instance:

1. **Connects** to the broker at boot via `:emqtt.connect/1` using
   the `:broker` keyword list (host, port, username, password,
   keepalive — all standard emqtt opts). The broker address is a
   mDNS hostname by convention (e.g. `ovcs1-vms.local`), resolved
   by `mdns_lite` on the vehicle LAN, so no static IPs are needed.
2. **Subscribes** to `<topic_prefix>/<name>` on the broker for
   every name in the relay's topic list (QoS 0). The broker then
   fans out any message published to that topic to all subscribed
   clients.
3. **Publishes** outbound. When a local `OvcsBus` broadcast
   matches one of the configured names and has `:relay_origin ==
   nil`, the relay serialises the `%OvcsBus.Message{}` with
   `:erlang.term_to_binary/1` and publishes to
   `<topic_prefix>/<name>`.
4. **Forwards inbound**. Messages the broker delivers are decoded
   with `[:safe]`, tagged `:relay_origin = :mqtt`, and
   `local_broadcast`-ed on the subscribing firmware's bus.

Reconnection, backoff, and keepalive are handled by `emqtt`; if
the broker goes down the local bus keeps working unchanged, and
the relay reconnects automatically when the broker returns.
Messages published during a broker outage are not queued anywhere
(QoS 0 with an empty retain flag) — intentional, since stale
status is worse than none. Raise QoS or flip `retain: true` in
the broker opts only for messages where delivery-after-reconnect
is genuinely desired.

### Choosing topics and client ids

- `topic_prefix` should scope to the vehicle (`ovcs/<vehicle>/bus`)
  so multiple vehicles on the same broker don't collide.
- `client_id` must be **unique per firmware instance** — otherwise
  MQTT will disconnect the older session when a new one with the
  same id connects. The convention is
  `<vehicle>-<side-or-bridge-id>`, e.g. `ovcs1-vms`,
  `ovcs1-infotainment`, `ovcs1-radio-control`.

### Broker hosting — `OvcsBus.Broker`

One firmware per vehicle runs the broker. By convention that's the
VMS — which is why the default hostname in examples is
`<vehicle>-vms.local`. Rather than provisioning a separate service,
this library ships a supervised wrapper:

```elixir
# vehicles/<vehicle>/lib/<vehicle>/vms/composer.ex
@impl VmsCore.Vehicle
def bus_broker do
  %{port: 1884}
end
```

`VmsCore.Application` reads `bus_broker/0` and adds
`{OvcsBus.Broker, opts}` to the VMS supervision tree. The broker
module spawns `mosquitto -c <generated-config>` via `MuonTrap`, so
a crash is restarted automatically. A minimal listener +
allow-anonymous config is written at boot; override via `:config`
or `:config_path` for auth/TLS setups. See the moduledoc for the
full opts list.

**Runtime requirement**: `mosquitto` must be on the firmware's
PATH. Upstream Nerves systems don't ship it — add
`BR2_PACKAGE_MOSQUITTO=y` to a Nerves system fragment (and rebuild
the system), or deploy Mosquitto out-of-firmware (e.g. on a
companion Pi) and skip `bus_broker/0` entirely. Relay clients only
care about the broker's address, not where it runs.

## Layout

```
lib/
  ovcs_bus.ex              — subscribe/broadcast wrapper
  ovcs_bus/
    application.ex         — starts Phoenix.PubSub(name: OvcsBus)
    message.ex             — %OvcsBus.Message{} struct
    relay.ex               — relay contract moduledoc
    relay/mqtt.ex          — emqtt-backed cross-bus relay
```

## Dependencies

- `phoenix_pubsub` — the underlying registry.
- `emqtt` — MQTT client for the relay. Pulled in unconditionally so
  `OvcsBus.Relay.Mqtt` is always available; target builds link
  `quicer` through the Nerves toolchain, host builds need `cmake`
  + `libmnl-dev` (see `docs/getting_started.md`).
