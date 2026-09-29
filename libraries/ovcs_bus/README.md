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
- **Deployed Nerves** — `nerves@<vehicle>-<role>.local` long names;
  peers share the sname `nerves` and the `.local` domain and vary the
  hostname.

In both, underscores in the vehicle directory and the bridge id
become dashes: the OVCS Mini's VMS is `ovcs-mini-vms@<host>` on the
host, and its `radio_control` bridge `ovcs-mini-bridge-radio-control`.

It calls `Node.connect/1` on each peer and retries on a 2-second
tick so nodes that boot later are folded into the mesh. Once every
node is connected, `Phoenix.PubSub.broadcast/3` carries the message
to all subscribers on all nodes natively.

On the host, `./ovcs run` starts each BEAM with `--sname` and
`--cookie ovcs`. A Nerves release boots unnamed, so
`OvcsBus.Distribution.ensure_started/0`, called on every Cluster
tick, starts distribution when the firmware's target config sets:

```elixir
config :ovcs_bus, :distribution, domain: "local"
```

It runs `epmd -daemon`, then `Node.start/2` as
`nerves@<hostname>.local` with long names, where `<hostname>` is the
`<vehicle>-<role>` hostname erlinit sets from `hostname_pattern`. No
IP address is needed for that, so it succeeds before the network is
up; a failure is logged and retried on the next tick. The peer list
is derived again on every tick, so it follows the node name.

Erlang's resolver has no mDNS support, so each firmware enables
mdns_lite's DNS bridge (`dns_bridge_enabled: true` on
`127.0.0.53:53`) and lists it first in VintageNet's
`additional_name_servers`. `.local` peer names then resolve for
`Node.connect/1`; other names are refused by the bridge and fall
through to the DHCP-supplied servers.

```
┌──────────────────┐       ┌──────────────────────┐       ┌──────────────────┐
│ VMS BEAM         │ dist  │ Infotainment BEAM    │ dist  │ Bridge BEAM(s)   │
│ OvcsBus ◄────────┼───────┼─► OvcsBus            │◄──────┼─► OvcsBus        │
│ + OvcsBus.Cluster│       │ + OvcsBus.Cluster    │       │ + OvcsBus.Cluster│
└──────────────────┘       └──────────────────────┘       └──────────────────┘
```

No MQTT broker, no separate protocol — just Erlang distribution.
The cookie `ovcs` is shared by every firmware release (`cookie:
"ovcs"` in its `mix.exs`, passed to the VM by `-setcookie` in
`rel/vm.args.eex`) and every `./ovcs run` child, so joining the
cluster is automatic as soon as peers resolve.

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
    distribution.ex         — starts distribution on deployed firmware
    message.ex              — %OvcsBus.Message{} struct
```

## Dependencies

- `phoenix_pubsub` — the underlying pub/sub registry.
