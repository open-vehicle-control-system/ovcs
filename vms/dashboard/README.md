# VMS Dashboard

Real-time debug dashboard for the Vehicle Management System. React SPA that
reads the layout (pages + blocks) published by [`vms_api`](../api) and
renders metric tables and live line charts driven by Phoenix channels.

[Dashboard pages](../../docs/vms/dashboard_pages.md) explains what it renders and how a vehicle declares it. Used during development and when a vehicle is bench-tested. The firmware
build script (`../firmware/build.sh`) bundles this dashboard into the VMS
Nerves image, so production hardware ships with the static build.

## Stack

- React 19, [zustand](https://zustand.docs.pmnd.rs/) (state)
- [`@ovcs/ui`](../../libraries/ovcs_ui) (the frame, components and light/dark theme shared with the vision dashboard), TailwindCSS
- [ECharts](https://echarts.apache.org/) (line charts, loaded only by pages that have one)
- `fetch` (REST), `phoenix` JS client (WebSocket channels)
- Vite + Vitest

## Running locally

```sh
cd vms/dashboard
npm install
npm run dev           # http://localhost:5173
```

Needs a reachable VMS API at `VITE_BASE_URL` (default `http://localhost:4000`).
Start it separately with `./ovcs run <vehicle>` from the repo root, or
`cd vms/api && VEHICLE=Ovcs1 mix phx.server`.

## Environment

| Variable | Purpose | Default |
|----------|---------|---------|
| `VITE_BASE_URL` | VMS API base URL for REST | `http://localhost:4000` |
| `VITE_BASE_WS` | VMS API base URL for the WebSocket | `ws://localhost:4000` |

## Data flow

1. On boot, fetches `/api/vehicle` and `/api/vehicle/pages` together; a
   page fetches `/api/vehicle/pages/:page_id/blocks` when it opens.
2. Opens one Phoenix socket to `/sockets/dashboard` and joins the
   `metrics` channel once, with the vehicle's refresh interval.
3. Each page pushes `subscribe` for every metric its blocks show when it
   opens, and `unsubscribe` for the same set when it closes. After a
   reconnect, the rejoin subscribes the open page's metrics again.
4. The Network page joins `network-interfaces` while it is open.
5. Action rows `POST /api/actions` with a payload the component's
   `trigger_action/2` handler understands; a refusal shows under the row.

## Production build

```sh
npm run build         # emits ../api/priv/static, consumed by ../firmware/build.sh
```

This is invoked automatically when you build VMS firmware; running it
directly is only useful for CI or previewing the bundled output.
