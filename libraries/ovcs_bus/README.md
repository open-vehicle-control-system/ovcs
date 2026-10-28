# OvcsBus

The guide, [The OVCS bus](../../docs/bus.md), explains the bus, its messages and the mesh. This README keeps the library's developer details.

Pub/sub bus of the VMS, infotainment, and bridge firmwares. Thin
wrapper around `Phoenix.PubSub`, with `OvcsBus.Cluster` stitching
every OVCS BEAM into a distributed Erlang mesh at boot. `broadcast/2`
stays on the local node.

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

`broadcast/2` delivers to subscribers on the local node only. A send
across the cluster suspends the publisher while the link to a peer is
saturated, so a slow link would stall the component that published;
components on different boards coordinate over CAN instead.
`OvcsBus.Forwarder` batches a node's messages to a collector on
another node without that stall.

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
tick so nodes that boot later are folded into the mesh. Bus messages
do not travel over it; it lets processes and remote shells on one node
reach the others.

On the host, `./ovcs run` starts each BEAM with `--sname` and the
user's `~/.erlang.cookie`. A Nerves release boots unnamed, so
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

The cookie `ovcs` is shared by every firmware release (`cookie:
"ovcs"` in its `mix.exs`, passed to the VM by `-setcookie` in
`rel/vm.args.eex`), and the `./ovcs run` children share the user's
`~/.erlang.cookie`, so joining the cluster is automatic as soon as
peers resolve.

### When a node is down

`Node.connect/1` returns `false` and the peer stays out of the mesh.
The retry loop reconnects as soon as the peer comes back.

### Security

The cluster assumes a trusted LAN — anyone who reaches epmd on a
firmware device with the correct cookie can join. Fine for a
vehicle LAN; revisit if you ever put an OVCS node on a shared
network.

## Layout

```
lib/
  ovcs_bus.ex               — subscribe/unsubscribe/broadcast wrapper
  ovcs_bus/
    application.ex          — starts Phoenix.PubSub(name: OvcsBus)
    cluster.ex              — boot-time Node.connect/1 retry loop
    distribution.ex         — starts distribution on deployed firmware
    forwarder.ex            — batches a node's messages to a remote collector
    message.ex              — %OvcsBus.Message{} struct
```

## Dependencies

- `phoenix_pubsub` — the underlying pub/sub registry.
