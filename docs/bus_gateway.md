---
title: Bus gateway
description: The bridge that exposes every signal on the OVCS bus over MQTT, HTTP and WebSocket, and how to enable it in your vehicle, with the OVCS Mini reference vehicle as the worked example.
---

Every component of a vehicle publishes its state as `%OvcsBus.Message{}` on the OVCS bus, and the bus stops at the Erlang mesh. The bus gateway, `OvcsBusGateway`, is a bridge library that carries those signals out: to an MQTT broker, to HTTP clients, and to a browser dashboard. It is part of the framework and contains nothing vehicle-specific; a vehicle opts in with one bridge entry and one config callback.

## How a signal gets out

```text
 vms node        infotainment node         gateway node (a bridge firmware)
 OvcsBus            OvcsBus                Collector ──> Cache (ETS)
   │ Forwarder        │ Forwarder             │
   └──────── batch ───┴────────────────────> ├──> Subscribers ──> Mqtt
                                              └──────────────────> Http / WebSocket
```

The gateway's `OvcsBusGateway.Collector` starts one `OvcsBus.Forwarder` on every node of the mesh, including nodes that join later. Each forwarder subscribes to its node's `"messages"` topic and sends batches to the collector:

- Between two ticks it keeps only the latest value of each `{source, name}` signal, and drops a value equal to the one it last sent. A chatty signal costs one entry per change, not one per publication.
- Batches go out with `:nosuspend`. When the distribution link is saturated the batch stays pending for the next tick, so no publisher ever waits on the mesh. This is why the gateway uses the forwarder rather than `OvcsBus.broadcast/2` with `cluster_broadcast: true`.
- A skipped tick is counted and reported as the `skipped_ticks` signal, sourced by `OvcsBus.Forwarder`. It appears on the gateway like any other signal.

The collector turns each batch into `OvcsBusGateway.Envelope`s, stores the latest one per signal in `OvcsBusGateway.Cache`, and dispatches them to the adapters through `OvcsBusGateway.Subscribers`. The batch interval is `forward_interval` in the gateway config.

Because repeats are dropped, a signal that holds its value sends nothing, and its envelope keeps the timestamp of its last change. To tell a steady signal from a node that is gone, the collector also publishes each node's presence as a signal of its own: source `OvcsBusGateway.Collector`, name `connected`, `node` the node's role, `true` when it starts a forwarder on the node, `false` when the node leaves the mesh. It goes through the cache and every adapter like any other signal.

Nothing safety-relevant depends on the gateway. It only reads the bus. The gateway's subtree is a temporary child of the bridge supervisor with its own restart limit (10 restarts in 60 seconds): a gateway that keeps crashing stops alone and leaves the other bridges of the firmware running. A failure while the subtree starts at boot, such as the HTTP port already being taken, still fails the start of the bridge supervisor.

## Enable it in your vehicle

The gateway runs in a bridge firmware, so it needs an entry in your vehicle's `bridge_firmwares/0` and a config callback. See [Your vehicle package](./vehicle_package.md) for bridge firmwares.

The OVCS Mini reference vehicle adds it to its `"ros"` bridge. The same two changes work on your vehicle:

```elixir
@behaviour OvcsBusGateway

# in bridge_firmwares/0
"ros" => %{
  target: :ovcs_base_can_system_rpi4,
  bridges: [RosBridge, OvcsBusGateway],
  # ...
}

@impl OvcsBusGateway
def ovcs_bus_gateway_config(:host),
  do: %OvcsBusGateway.Config{
    mqtt: [host: System.get_env("MQTT_HOST", "127.0.0.1"), port: 1883]
  }

def ovcs_bus_gateway_config(:target),
  do: %OvcsBusGateway.Config{
    mqtt: [host: Application.get_env(:ovcs_bus_gateway, :mqtt_host, "127.0.0.1"), port: 1883]
  }
```

`OvcsBusGateway.Config` selects the adapters:

| Field | Default | Effect |
|---|---|---|
| `:http` | `[port: 4100]` | HTTP and WebSocket adapter; `nil` turns it off |
| `:mqtt` | `nil` | MQTT adapter, `[host: ..., port: ...]`; `nil` leaves it off |
| `:forward_interval` | `20` | milliseconds between batches from each node |

Rebuild and upload every firmware of your vehicle (VMS, infotainment and every bridge), not only the bridge that hosts the gateway. A node whose firmware predates `OvcsBus.Forwarder` has no forwarder module, so its signals never appear; the collector keeps retrying such a mesh peer every second and logs it at info level.

On the Mini's firmware the broker address comes from `MQTT_HOST`, which defaults to `ZENOH_ENDPOINT_IP` and then `127.0.0.1`: the broker runs on the compute node next to the Zenoh router. Like `ZENOH_ENDPOINT_IP`, it is baked into the bridge firmware at build time: set it in `vehicles/<vehicle>/.env.exs` and rebuild the bridge to change it.

Building a bridge firmware for a target also builds the [dashboard](#dashboard), so it needs Node.js and npm.

## Envelope

Every signal leaves the gateway as one JSON object, built by `OvcsBusGateway.Envelope`:

```json
{
  "node": "vms",
  "source": "VmsCore.Vehicle",
  "name": "ready_to_drive",
  "value": true,
  "unit": null,
  "timestamp": 1761565200123
}
```

| Field | Meaning |
|---|---|
| `node` | role of the node that published the signal: `vms`, `infotainment`, `bridge-<id>` |
| `source` | the publishing module, as `inspect/1` prints it |
| `name` | the signal name |
| `value` | the value, encoded as below |
| `unit` | the unit of a physical value, or `null` |
| `timestamp` | milliseconds since the Unix epoch, taken on the publishing node when its forwarder received the message; since repeats are dropped, the time of the value's last change, not of its last publication |

Values are encoded so any JSON client can read them: numbers, booleans, `null` and UTF-8 strings are kept; a finite `Decimal` becomes an exact JSON number; any other atom becomes its name; anything else, including non-UTF-8 binaries and non-finite decimals, becomes its `inspect/1` text.

## MQTT

With `:mqtt` set, the gateway keeps a connection to the broker and publishes each envelope as JSON, retained, at QoS 0, on:

```text
ovcs/<vehicle>/<node>/<source>/<name>
```

`<vehicle>` is the underscored vehicle module name (`ovcs_mini`); the other segments are the envelope's fields. A client subscribed to `ovcs/ovcs_mini/#` receives the last value of every signal immediately, then each change.

- The gateway connects with client id `ovcs_bus_gateway_<vehicle>_<firmware>_<arm>`, `<firmware>` being the bridge firmware's id (`ros`) and `<arm>` `host` or `target`, so the vehicle's gateways and one started with `./ovcs run` can share a broker.
- `ovcs/<vehicle>/gateway/online` tells whether the gateway is connected: it publishes `true` there, retained, on every connect, and its last will has the broker publish `false`, retained, when the connection is lost. A client that sees `false` knows every other retained value may be stale.
- On every connect and reconnect, after `online`, the gateway republishes its whole cache, so the retained values cover every signal, including those that never change.
- Publishing never blocks the gateway. While the broker is unreachable nothing is published and nothing is buffered; the client retries with a backoff of up to 30 seconds. A send stuck for a second closes the connection, and batches that arrive while more than 1000 messages wait are dropped; the republish on the next connect restores the retained values.

Subscribe from any machine that reaches the broker:

```sh
mosquitto_sub -h <broker> -t 'ovcs/<vehicle>/#' -v
```

## HTTP and WebSocket

With `:http` set, the gateway serves on port 4100:

| Route | Returns |
|---|---|
| `GET /api/signals` | the latest envelopes, as a JSON list |
| `GET /api/signals/:node/:source/:name` | one envelope, or 404 |
| `GET /ws` | a WebSocket stream of envelopes |
| `GET /` | the [dashboard](#dashboard) |

`/api/signals` and `/ws` take optional `node`, `source` and `name` query parameters; a missing one matches everything:

```sh
curl 'http://<bridge-host>:4100/api/signals?node=vms&name=ready_to_drive'
```

The WebSocket is server to client only. It sends a `snapshot` frame with the cached envelopes of the filter on connect, then an `update` frame for each batch that contains a matching envelope:

```json
{"type": "update", "signals": [{"node": "vms", "source": "VmsCore.Vehicle", "name": "ready_to_drive", "value": true, "unit": null, "timestamp": 1761565200123}]}
```

The first `update` frames may repeat envelopes of the snapshot or carry older ones: compare `timestamp` and keep the newer. The server pings every 30 seconds so a quiet stream stays open. A client that falls behind, with more than 1000 messages queued, is closed with code 1013: reconnect and use the new snapshot.

## Dashboard

`libraries/ovcs_bus_gateway/dashboard/` is a Vue app that groups every signal by node and source, with a filter box and a connection indicator, fed by `/ws`. It is built into `priv/static` and served at `/` by the gateway. `bridges/firmware/build.sh` builds it before every non-host firmware build, so a burned bridge serves it at `http://<bridge-host>:4100/`.

Its design tokens and Tailwind preset come from [`@ovcs/ui`](../libraries/ovcs_ui/README.md), shared by OVCS web UIs.

## Developing on the host

`./ovcs run <vehicle>` starts the bridge firmware with the gateway on the host, publishing to `MQTT_HOST` (default `127.0.0.1`). Start a broker without a vehicle with the `standalone` profile of [`compose/local`](../compose/README.md):

```sh
docker compose -f compose/local/base.yml --profile standalone up -d mosquitto
```

On a vehicle, the broker is the `mosquitto` service of the compute node's stack, [`compose/compute`](../compose/compute/README.md). It allows anonymous clients and keeps nothing on disk, because the vehicle network is the security boundary.

To work on the dashboard with hot reload against a running gateway:

```sh
cd libraries/ovcs_bus_gateway/dashboard
npm install
npm run dev
```

Vite proxies `/api` and `/ws` to `localhost:4100`. If `priv/static` has not been built, `GET /` answers 404 with a note to run `npm run build`.
