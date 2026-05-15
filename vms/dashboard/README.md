# VMS Dashboard

Real-time debug dashboard for the Vehicle Management System. Vue 3 SPA that
reads the layout (pages + blocks) published by [`vms_api`](../api) and
renders metric tables and live line charts driven by Phoenix channels.

Used during development and when a vehicle is bench-tested. The firmware
build script (`../firmware/build.sh`) bundles this dashboard into the VMS
Nerves image, so production hardware ships with the static build.

## Stack

- Vue 3, Vue Router, [Pinia](https://pinia.vuejs.org/) (state)
- [ECharts](https://echarts.apache.org/) + `vue-echarts` (line charts)
- TailwindCSS, Headless UI, Hero Icons
- `axios` (REST), `phoenix` JS client (WebSocket channels)
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
| `VITE_BASE_URL` | VMS API base URL used for REST + WebSocket | `http://localhost:4000` |

## Data flow

1. On boot, REST-fetches `/api/vehicle`, `/api/vehicle/pages`, and
   `/api/vehicle/pages/:page_id/blocks` to build the layout.
2. Opens a Phoenix socket to `/sockets/dashboard` and joins the `metrics`
   and `network-interfaces` channels.
3. A Pinia plugin (`src/stores/`) turns block definitions into channel
   subscriptions — each `module`/`key` pair a block references is
   subscribed to once and broadcast to whichever stores need it.
4. Actions from block buttons `POST /api/actions` with a payload the
   component's `trigger_action/2` handler understands.

## Production build

```sh
npm run build         # emits ./dist, consumed by ../firmware/build.sh
```

This is invoked automatically when you build VMS firmware; running it
directly is only useful for CI or previewing the bundled output.
