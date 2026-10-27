# OvcsBusGateway

Exposes the signals on the OVCS bus to the outside world.

Every bus signal leaves the gateway as an `OvcsBusGateway.Envelope`: a JSON object
carrying the originating node, the publishing module, the signal name, its value,
its unit and a millisecond timestamp.

## Adapters

- MQTT: every envelope retained on `ovcs/<vehicle>/<node>/<source>/<name>`.
- HTTP on port 4100: `/api/signals`, `/api/signals/:node/:source/:name`, a `/ws` WebSocket and the dashboard at `/`.

A vehicle enables the gateway with a `bridges:` entry and an `ovcs_bus_gateway_config/1` callback. See the [Bus gateway guide](../../docs/bus_gateway.md).

## Dashboard

`dashboard/` is a Vue app built into `priv/static`:

```sh
cd dashboard
npm install
npm run dev     # hot reload, proxies /api and /ws to localhost:4100
npm run build
npm run test:unit
```
