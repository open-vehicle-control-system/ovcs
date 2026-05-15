# OvcsBus

Cluster-wide pub/sub bus shared across the VMS, infotainment, and
bridge firmwares. Thin wrapper around `Phoenix.PubSub`, with
`OvcsBus.Cluster` stitching every OVCS BEAM into a distributed
Erlang mesh at boot so `broadcast/2` reaches subscribers on every
node with no separate transport.

## Why

Components (`VmsCore.Components.*`, managers, bridges, …) need a
decoupled way to publish intent + state without wiring GenServer
calls between each other. OvcsBus is that decoupling layer. Every
firmware that depends on `ovcs_bus` gets the registry started
automatically — no per-consumer supervision wiring.

## API

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

`broadcast/2` fans out to subscribers on every node in the cluster,
including the local one. Use `local_broadcast/2` for the rare case
you want to keep a message node-local.

`OvcsBus.Message`:
- `:name`          — short atom (e.g. `:ready_to_drive`, `:speed`).
- `:value`         — arbitrary payload.
- `:source`        — publishing module, used to disambiguate when
  several components publish the same name.

## Cross-firmware transport: distributed Erlang

`OvcsBus.Cluster` is a small GenServer supervised by each core's
`Application`. At boot it derives the peer node list from the
vehicle module's declared roles (`vms`, optional `infotainment`,
each `bridge_firmwares/0` entry) and the local node's naming
convention:

- **Host dev** — `<vehicle>-<role>@<host>` snames; peers share `<host>`.
- **Deployed Nerves** — `nerves@<vehicle>-<role>` node names; peers
  share the sname `nerves` and vary the hostname (resolved via
  mDNS through `nerves_pack`).

It calls `Node.connect/1` on each peer and retries on a 2-second
tick so nodes that boot later are folded into the mesh. Once every
node is connected, `Phoenix.PubSub.broadcast/3` carries the message
to all subscribers on all nodes natively.

```
┌──────────────────┐       ┌──────────────────────┐       ┌──────────────────┐
│ VMS BEAM         │ dist  │ Infotainment BEAM    │ dist  │ Bridge BEAM(s)   │
│ OvcsBus ◄────────┼───────┼─► OvcsBus            │◄──────┼─► OvcsBus        │
│ + OvcsBus.Cluster│       │ + OvcsBus.Cluster    │       │ + OvcsBus.Cluster│
└──────────────────┘       └──────────────────────┘       └──────────────────┘
```

No MQTT broker, no separate protocol, no config file — just Erlang
distribution. `--cookie ovcs` is shared across every firmware
release (and every `./ovcs run` child), so joining the cluster is
automatic as soon as peers resolve.

### When a node is down

`Node.connect/1` returns `false`, the peer stays out of the mesh,
and `broadcast/3` silently skips it — same QoS-0 semantics you'd
get from MQTT at QoS 0. The retry loop reconnects as soon as the
peer comes back.

### Security

The cluster assumes a trusted LAN — anyone who reaches epmd on a
firmware device with the correct cookie can join. Fine for a
vehicle LAN; revisit if you ever put an OVCS node on a shared
network.

## Layout

```
lib/
  ovcs_bus.ex               — subscribe/broadcast/local_broadcast wrapper
  ovcs_bus/
    application.ex          — starts Phoenix.PubSub(name: OvcsBus)
    cluster.ex              — boot-time Node.connect/1 retry loop
    message.ex              — %OvcsBus.Message{} struct
```

## Dependencies

- `phoenix_pubsub` — the underlying pub/sub registry.
