# OvcsBus

The guide, [The OVCS bus](../../docs/bus/README.md), explains the bus, its messages and the mesh. This README keeps the library's developer details.

Pub/sub bus of the VMS, infotainment, and bridge firmwares. Thin
wrapper around `Phoenix.PubSub`, with `OvcsBus.Cluster` stitching
every OVCS BEAM into a distributed Erlang mesh at boot. `broadcast/2`
stays on the local node.

## Where things are explained

- Messages, `subscribe/1` and `broadcast/2`, the node-local scope: [The OVCS bus](../../docs/bus/README.md#messages).
- The mesh: peers, node names, cookies, `OvcsBus.Distribution` and `.local` resolution: [The mesh](../../docs/bus/README.md#the-mesh).
- `OvcsBus.Forwarder`: [Seeing the bus from outside](../../docs/bus/README.md#seeing-the-bus-from-outside).

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
    units.ex                — unit functions for Message.unit
```

## Dependencies

- `phoenix_pubsub` — the underlying pub/sub registry.
