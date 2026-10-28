# OvcsBusGateway

Exposes the signals on the OVCS bus to the outside world.

Every bus signal leaves the gateway as an `OvcsBusGateway.Envelope`: a JSON object
carrying the originating node, the publishing module, the signal name, its value,
its unit, when its value last changed, when it was last published, and whether
the gateway considers it stale.

## Adapters

- MQTT: every envelope retained on `ovcs/<vehicle>/<node>/<source>/<name>`.
- HTTP on port 4100, a Phoenix endpoint: `/api/signals`, `/api/signals/:node/:source/:name`, a Phoenix Channels socket at `/socket` streaming the `signals` topic, and the dashboard at `/`.

A firmware hosts the gateway by adding its child spec to a supervisor:

```elixir
{OvcsBusGateway, vehicle: MyVehicle, config: %OvcsBusGateway.Config{}, mqtt_client_id: "..."}
```

The bridge firmware does so for a `bridge_firmwares/0` entry with a `bus_gateway:` key. See the [Bus gateway guide](../../docs/bus_gateway.md).

## Dashboard

`dashboard/` is a Vue app built into `priv/static`:

```sh
cd dashboard
npm install
npm run dev     # hot reload, proxies /api and /socket to localhost:4100
npm run build
npm run test:unit
```
