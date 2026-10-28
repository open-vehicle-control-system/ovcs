---
title: Bus gateway
description: The library that exposes every signal on the OVCS bus over MQTT, HTTP and Phoenix Channels, and how to enable it in your vehicle, with the OVCS Mini reference vehicle as the worked example.
---

The bus gateway, `OvcsBusGateway`, carries the signals of the [OVCS bus](./bus.md) out of the Erlang mesh: to an MQTT broker, to HTTP clients, and to a browser dashboard. It is a library in the framework and contains nothing vehicle-specific. Any OVCS firmware can host it by adding its child spec, `{OvcsBusGateway, vehicle: ..., config: ...}`; your vehicle declares it among the `children:` of a `bridge_firmwares/0` entry to run it in that bridge firmware.

## How a signal gets out

```text
 vms node        infotainment node         gateway node (a bridge firmware)
 OvcsBus            OvcsBus                Collector ──> Cache (ETS)
   │ Forwarder        │ Forwarder             │
   └──────── batch ───┴────────────────────> ├──> Subscribers ──> Mqtt
                                              └──────────────────> Http (Phoenix)
```

The gateway's `OvcsBusGateway.Collector` starts one [`OvcsBus.Forwarder`](./bus.md#seeing-the-bus-from-outside) on every node of the mesh, including nodes that join later, and receives their batches. Once a forwarder has skipped a tick, its running total appears on the gateway as the `skipped_ticks` signal, sourced by `OvcsBus.Forwarder`, like any other signal.

The collector turns each batch into `OvcsBusGateway.Envelope`s, stores the latest one per signal in `OvcsBusGateway.Cache`, and dispatches them to the adapters through `OvcsBusGateway.Subscribers`. The batch interval is `forward_interval` in the gateway config.

Each envelope carries two times: `changed_at`, the last change of the value, and `published_at`, the last time the component published it. A signal that holds its value is refreshed while its component keeps publishing, so `published_at` advances about once a second. The gateway decides staleness: once a second it sets `stale: true` on every signal it has not received for 3 seconds and sends that envelope out again, and the next envelope it receives for the signal clears it to `stale: false`. A component that publishes a signal less often than every few seconds shows it as stale between publications.

To tell a quiet node from a node that is gone, the collector also publishes each node's presence as a signal of its own: source `OvcsBusGateway.Collector`, name `connected`, `node` the node's role, `true` when it starts a forwarder on the node, `false` when the node leaves the mesh. It goes through the cache and every adapter like any other signal. It is not refreshed, since it is sent only when the collector starts a forwarder on the node or loses the node, so the stale rule does not apply to it: it carries `stale: null`.

Nothing safety-relevant depends on the gateway. It only reads the bus. The gateway's subtree is a temporary child with its own restart limit (10 restarts in 60 seconds). A gateway that cannot start, for example because the HTTP port is already taken, or that keeps crashing stops alone with an error in the log, and the rest of the firmware keeps running.

## Enable it in your vehicle

Your vehicle runs the gateway in a bridge firmware by listing its child spec in the `children:` of that firmware's `bridge_firmwares/0` entry. `OvcsBridge.Supervisor` starts these children after the entry's bridges; a `%{host: [...], target: [...]}` map picks them per build target. See [Your vehicle package](./vehicle_package.md) for bridge firmwares.

The child spec takes:

| Option | Default | Effect |
|---|---|---|
| `:vehicle` | required | your vehicle module: names the node roles and the `<vehicle>` MQTT topic segment |
| `:config` | `%OvcsBusGateway.Config{}` | the adapters, below |
| `:mqtt_client_id` | `ovcs_bus_gateway_<vehicle>` | the MQTT client id, unique per gateway on one broker |

The OVCS Mini reference vehicle runs it in its `"ros"` bridge firmware. The same works in an entry of your vehicle:

```elixir
# in bridge_firmwares/0
"ros" => %{
  target: :ovcs_base_can_system_rpi4,
  bridges: [RosBridge],
  children: %{host: [bus_gateway(:host)], target: [bus_gateway(:target)]},
  # ...
}

defp bus_gateway(arm) do
  {OvcsBusGateway,
   vehicle: __MODULE__,
   config: %OvcsBusGateway.Config{mqtt: [host: mqtt_broker(arm), port: 1883]},
   mqtt_client_id: "ovcs_bus_gateway_ovcs_mini_ros_#{arm}"}
end

defp mqtt_broker(:host), do: "127.0.0.1"
defp mqtt_broker(:target), do: "10.42.0.1"
```

`OvcsBusGateway.Config` selects the adapters:

| Field | Default | Effect |
|---|---|---|
| `:http` | `[port: 4100]` | HTTP and Phoenix Channels adapter; `nil` turns it off |
| `:mqtt` | `nil` | MQTT adapter, `[host: ..., port: ...]`; `nil` leaves it off |
| `:forward_interval` | `20` | milliseconds between batches from each node |

Rebuild and upload every firmware of your vehicle (VMS, infotainment and every bridge), not only the bridge that hosts the gateway. A node whose firmware predates `OvcsBus.Forwarder` has no forwarder module, so its signals never appear; the collector keeps retrying such a mesh peer every second and logs it at info level. A node whose forwarder predates `published_at` still delivers its signals, with `published_at` and `stale` set to `null`: that forwarder does not refresh, so the gateway cannot tell whether its signals are stale.

Your vehicle package chooses the broker address. The Mini publishes to a broker on the host under `./ovcs run`, and on the vehicle to its compute node at `10.42.0.1`, the node's fixed address on the vehicle network. Changing it on the vehicle means rebuilding the bridge firmware that hosts the gateway.

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
  "changed_at": 1761565200123,
  "published_at": 1761565204310,
  "stale": false
}
```

| Field | Meaning |
|---|---|
| `node` | role of the node that published the signal: `vms`, `infotainment`, `bridge-<id>` |
| `source` | the publishing module, as `inspect/1` prints it |
| `name` | the signal name |
| `value` | the value, encoded as below |
| `unit` | the unit of a physical value, or `null` |
| `changed_at` | milliseconds since the Unix epoch, taken on the publishing node when its forwarder received the message that last changed the value |
| `published_at` | milliseconds since the Unix epoch, taken the same way on the last message, changed or not; refreshed about once a second while the component publishes; `null` from a node whose firmware does not report it |
| `stale` | `true` when the gateway has not received the signal for 3 seconds, `false` while it does, `null` when unknown: presence signals and nodes whose firmware does not refresh |

Values are encoded so any JSON client can read them: numbers, booleans, `null` and UTF-8 strings are kept; a finite `Decimal` becomes an exact JSON number; any other atom becomes its name; anything else, including non-UTF-8 binaries and non-finite decimals, becomes its `inspect/1` text.

## MQTT

With `:mqtt` set, the gateway keeps a connection to the broker and publishes each envelope as JSON, retained, at QoS 0, on:

```text
ovcs/<vehicle>/<node>/<source>/<name>
```

`<vehicle>` is the underscored vehicle module name (`ovcs_mini`); the other segments are the envelope's fields. A client subscribed to `ovcs/ovcs_mini/#` receives the last value of every signal immediately, then each change and each refresh.

- The gateway connects with its `:mqtt_client_id`. The Mini's are `ovcs_bus_gateway_ovcs_mini_ros_host` and `ovcs_bus_gateway_ovcs_mini_ros_target`, so the vehicle's gateway and one started with `./ovcs run` can share a broker; give each gateway of your vehicle its own.
- `ovcs/<vehicle>/gateway/online` tells whether the gateway is connected: it publishes `true` there, retained, on every connect, and its last will has the broker publish `false`, retained, when the connection is lost. A client that sees `false` knows every other retained value may be stale.
- On every connect and reconnect, after `online`, the gateway republishes its whole cache, so the retained values cover every signal, including those that never change.
- Publishing never blocks the gateway. While the broker is unreachable nothing is published and nothing is buffered; the client retries with a backoff of up to 30 seconds. A send stuck for a second closes the connection, and batches that arrive while more than 1000 messages wait are dropped; the republish on the next connect restores the retained values.

Subscribe from any machine that reaches the broker:

```sh
mosquitto_sub -h <broker> -t 'ovcs/<vehicle>/#' -v
```

The broker also accepts MQTT over WebSocket at `ws://<broker>:9001`, for clients running in a browser. To browse its topics from a laptop, a desktop client such as MQTT Explorer pointed at `<broker>:1883` keeps the connection between sessions.

## HTTP and Phoenix Channels

With `:http` set, the gateway runs a Phoenix endpoint, `OvcsBusGateway.Http.Endpoint`, on port 4100:

| Route | Returns |
|---|---|
| `GET /api/signals` | the latest envelopes, as a JSON list |
| `GET /api/signals/:node/:source/:name` | one envelope, or 404 |
| `/socket` | a Phoenix Channels socket streaming envelopes on the `signals` topic |
| `GET /` | the [dashboard](#dashboard) |

`/api/signals` takes optional `node`, `source` and `name` query parameters; a missing or empty one matches everything:

```sh
curl 'http://<bridge-host>:4100/api/signals?node=vms&name=ready_to_drive'
```

The live stream is the `signals` channel of the `/socket` socket. The join parameters are the filter, with the same three optional keys. After the join the channel pushes:

| Event | Payload |
|---|---|
| `snapshot` | `{"signals": [...]}`, the cached envelopes of the filter |
| `update` | `{"signals": [...]}`, the matching envelopes of each batch, refreshes included; nothing for a batch without any |
| `overloaded` | `{}`, then the channel closes: the client fell behind, with more than 1000 messages queued |

A Phoenix channel client exists for JavaScript, the `phoenix` npm package the dashboard uses, and for other languages. It rejoins after a dropped connection and receives a new `snapshot`; after `overloaded` the client joins again itself. With the JavaScript client:

```javascript
import { Socket } from 'phoenix'

const socket = new Socket('ws://<bridge-host>:4100/socket')
socket.connect()

const channel = socket.channel('signals', { node: 'vms' })
channel.on('snapshot', ({ signals }) => console.log('snapshot', signals))
channel.on('update', ({ signals }) => console.log('update', signals))
channel.join()
```

The first `update` events may repeat envelopes of the snapshot or carry older ones: compare `published_at` (or `changed_at` when `published_at` is `null`) and keep the newer. A signal turning stale arrives in an `update` with `stale: true`. A client that cannot speak Phoenix Channels subscribes to the broker instead: MQTT is the protocol-neutral way out of the gateway.

## Dashboard

`libraries/ovcs_bus_gateway/dashboard/` is a Vue app that groups every signal by node and source, with a filter box and a connection indicator, fed by the `signals` channel. Each row shows how long ago the value last changed and was last published; a dot marks a value that changed in the last 2 seconds, and a signal the gateway flags as stale is muted and labelled. It is built into `priv/static` and served at `/` by the gateway. `bridges/firmware/build.sh` builds it before every non-host firmware build, so a burned bridge serves it at `http://<bridge-host>:4100/`.

Its design tokens and Tailwind preset come from [`@ovcs/ui`](../libraries/ovcs_ui/README.md), shared by OVCS web UIs.

## Developing on the host

`./ovcs run <vehicle>` starts the bridge firmware with the gateway on the host, publishing to the broker your vehicle names for the host arm (`127.0.0.1` on the Mini). Start a broker without a vehicle with the `standalone` profile of [`compose/local`](../compose/README.md):

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

The dev server proxies `/api` and `/socket` to `http://localhost:4100`. Point it at a vehicle's gateway with `OVCS_BUS_GATEWAY`, for example `OVCS_BUS_GATEWAY=http://ovcs-mini-bridge-ros.local:4100 npm run dev` on the OVCS Mini reference vehicle, or the same on your vehicle's bridge.

If `priv/static` has not been built, `GET /` answers 404 with a note to run `npm run build`.
