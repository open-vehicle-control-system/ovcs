---
title: The OVCS bus
description: The in-process message bus every OVCS firmware runs, its messages, how components publish and subscribe, and how its signals reach other boards.
---

Components do not call each other. They publish what they know on a bus and subscribe to what they need. Each firmware of a vehicle (VMS, infotainment, vision unit, every bridge) runs its own bus, `OvcsBus`, a thin wrapper around `Phoenix.PubSub`. It starts with the `ovcs_bus` application, so a firmware that depends on the library has it without any supervision wiring.

Do not confuse it with the `ovcs` CAN bus, the internal network described in [Architecture](../architecture.md#bus-isolation).

## Messages

Everything on the bus is an `%OvcsBus.Message{}`, published on the single topic `"messages"`:

| Field | Meaning |
|---|---|
| `name` | atom naming the signal: `:speed`, `:ready_to_drive` |
| `value` | the payload, any term |
| `source` | the publishing module; required |
| `unit` | the unit of a physical value, or `nil` |

`source` tells apart components that publish the same `name`. Subscribers gate on it: a component acts only on messages from the source its composer configured.

A configured source of `nil` is how a control level that commands nothing is expressed. A message with a `nil` source would match such a component, so `OvcsBus.broadcast/2` raises on it.

The publisher sets `unit`: it is the one component that knows what its value measures. Use the functions of [`OvcsBus.Units`](../../libraries/ovcs_bus/lib/ovcs_bus/units.ex) (`Units.volt()`, `Units.revolution_per_minute()`), so that a misspelt unit fails to compile instead of reaching a dashboard. States, flags and normalised requests carry no unit.

## Scope

A message is delivered to subscribers on its own node only. A send across the Erlang mesh can suspend the publisher while the link to the peer is busy, and a drivetrain component must never wait on a network. Components on different boards coordinate over CAN, where the VMS watches the freshness of what it receives. Nothing safety-relevant crosses the mesh.

## The mesh

`OvcsBus.Cluster` joins every BEAM of the vehicle into one Erlang-distribution cluster. At boot, and on a 2-second tick afterwards, it calls `Node.connect/1` on every peer the vehicle declares, so a board that starts later still joins. The peers are the VMS, the infotainment side and the vision unit if your vehicle has them, and one per entry of `bridge_firmwares/0`.

The bus gateway's forwarders and remote shells run over the mesh.

Node names follow the vehicle and the role, with underscores written as dashes:

| Where | Node name | Example (OVCS Mini reference vehicle) |
|---|---|---|
| Host, `./ovcs run` | `<vehicle>-<role>@<host>` | `ovcs-mini-vms@<host>` |
| Deployed Nerves | `nerves@<vehicle>-<role>.local` | `nerves@ovcs-mini-bridge-ros.local` |

A role is `vms`, `infotainment`, `vision` or `bridge-<id>`.

**On the host**, the CLI starts each BEAM with `--sname <vehicle>-<role>` and your `~/.erlang.cookie`. It creates the cookie with a random value if it is missing. The host BEAMs only dial each other, so nobody else on the network can join them.

**On a device**, a Nerves release boots without a node name. `OvcsBus.Distribution` starts distribution once the firmware's target config sets `config :ovcs_bus, :distribution, domain: "local"`:

1. On the first cluster tick, it runs `epmd -daemon`.
2. It starts distribution as `nerves@<vehicle>-<role>.local`, with long names.

The hostname part is the device hostname set by erlinit's `hostname_pattern`, which mdns_lite also advertises. Every release's cookie is `ovcs`, passed to the VM by `-setcookie` in `rel/vm.args.eex`, so the devices authenticate each other. Starting distribution needs no IP address. A failed start is logged and retried on the next tick.

Erlang's own resolver does not know mDNS. Each firmware enables mdns_lite's DNS bridge on `127.0.0.53` and lists it first in VintageNet's `additional_name_servers`, so a lookup of `<vehicle>-<role>.local` is answered from mDNS. The bridge refuses every other name, and the resolver moves on to the DHCP-supplied servers.

The module docs of [`OvcsBus.Cluster`](../../libraries/ovcs_bus/lib/ovcs_bus/cluster.ex) and [`OvcsBus.Distribution`](../../libraries/ovcs_bus/lib/ovcs_bus/distribution.ex) cover the rest.

A peer that is down stays out of the mesh and nothing waits for it.

Anyone who reaches the Erlang port mapper with the cookie can join the mesh, so run it on the vehicle's own network.

## Seeing the bus from outside

[`OvcsBus.Forwarder`](../../libraries/ovcs_bus/lib/ovcs_bus/forwarder.ex) carries a node's messages to a collector on another node without ever stalling a publisher. The collector starts one forwarder per node. Each subscribes to its node's `"messages"` topic and sends batches:

- Every 20 ms tick, it sends the latest value of each `{source, name}` signal that changed. A signal published often costs one entry per change, not one per publication.
- Batches use `:nosuspend`. If the link is saturated the batch waits for the next tick, so the publisher never notices.
- About once a second it re-sends signals that were republished with an unchanged value, so a collector can tell a steady signal from one whose component stopped.
- Skipped ticks are counted. Once one has been skipped, the running total is published every second as the `skipped_ticks` signal, sourced by `OvcsBus.Forwarder`.

The [bus gateway](./gateway.md) is the collector that ships with the framework. It turns these batches into MQTT topics, an HTTP API, a Phoenix Channels stream and a dashboard.

## Publishing and subscribing

Subscribe once, usually in `init/1`:

```elixir
OvcsBus.subscribe("messages")
```

Every subscriber receives every message, so match on `name` and `source`. Keep a catch-all clause so an unrelated message does not crash the process:

```elixir
def handle_info(%OvcsBus.Message{name: :speed, value: speed, source: source}, state)
    when source == state.speed_source do
  {:noreply, %{state | speed: speed}}
end

def handle_info(%OvcsBus.Message{}, state), do: {:noreply, state}
```

Publish from the component's own loop, naming itself as the source:

```elixir
OvcsBus.broadcast("messages", %OvcsBus.Message{
  name: :speed,
  value: state.speed,
  source: __MODULE__,
  unit: OvcsBus.Units.kilometre_per_hour()
})
```

The composer decides which module a component listens to: `speed_source: Polo9N.ABS` on one vehicle, `speed_source: OVCS.VehicleMotion` on another, with the same component code. [Add a component](../vms/add_a_component.md) shows the whole recipe. `VmsCore.Metrics` keeps the last value of every message for the dashboard and API.

## Where next

- [Bus gateway](./gateway.md): the signals over MQTT, HTTP and Phoenix Channels.
- [How the VMS works](../vms/how_it_works.md#the-component-pattern): the component pattern built on the bus.
- [Architecture](../architecture.md#one-erlang-mesh-no-broker): the roles the mesh joins.
