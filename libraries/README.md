# libraries/

Shared Elixir libraries used across `vms_core`, `infotainment_core`,
the bridge libraries, and the vehicle packages. Two flavours live
side-by-side:

- **In-tree** libraries are checked into this repo and versioned with
  the rest of OVCS.
- **Sideloaded** libraries live in their own upstream repos under
  [`open-vehicle-control-system`](https://github.com/open-vehicle-control-system).
  They are gitignored here (see [`.gitignore`](./.gitignore)) and
  cloned on demand by `mise run libraries` (invoked automatically by
  the `mise install` postinstall hook).

## Catalogue

| Directory | Source | Purpose |
|-----------|--------|---------|
| [`cantastic/`](./cantastic) | **sideloaded** — [open-vehicle-control-system/cantastic](https://github.com/open-vehicle-control-system/cantastic) | CAN bus library: YAML-driven frame specs, SocketCAN, ISO-TP, OBD2 |
| [`express_lrs/`](./express_lrs) | **sideloaded** — [open-vehicle-control-system/express_lrs](https://github.com/open-vehicle-control-system/express_lrs) | MAVLink v2 receive-only decoder for ExpressLRS handsets |
| [`msp_osd/`](./msp_osd) | **sideloaded** — [open-vehicle-control-system/msp_osd](https://github.com/open-vehicle-control-system/msp_osd) | MSP / DisplayPort OSD stack for HDZero / Walksnail / DJI VTXs |
| [`ovcs_control/`](./ovcs_control) | **sideloaded** — [open-vehicle-control-system/ovcs_control](https://github.com/open-vehicle-control-system/ovcs_control) | PID controller + input filters + interactive tuning sim |
| [`ovcs_bridge/`](./ovcs_bridge) | in-tree | `OvcsBridge` behaviour + supervisor for bridge libraries |
| [`ovcs_bus/`](./ovcs_bus) | in-tree | Cluster-wide pub/sub over Erlang distribution |
| [`ovcs_can/`](./ovcs_can) | in-tree | Shared per-component CAN frame YAMLs (no runtime logic) |
| [`ovcs_vehicle/`](./ovcs_vehicle) | in-tree | `OvcsVehicle` behaviour + `ovcs vehicle new` scaffold |

Each library has its own README — start there for usage and design notes.

## Cloning the sideloaded libraries

The standard `mise install` flow handles this for you:

```sh
mise install        # runs the postinstall hook → mise run bootstrap + mise run libraries
```

To (re)clone any missing sideloaded libraries without reinstalling
runtimes:

```sh
mise run libraries
```

The task only clones what's missing — existing clones are left alone,
so local edits and pulled branches in `libraries/cantastic/` etc. are
preserved. If you want to start from a clean upstream copy, delete the
directory first and re-run the task.

## Why some libraries are sideloaded and others aren't

Sideloaded libraries (`cantastic`, `express_lrs`, `msp_osd`,
`ovcs_control`) are reusable outside OVCS — they're published as their
own repos so external projects can depend on them without pulling the
whole OVCS monorepo. The in-tree libraries (`ovcs_bridge`, `ovcs_bus`,
`ovcs_can`, `ovcs_vehicle`) are OVCS-internal contracts and evolve in
lockstep with the rest of the codebase, so they live here.
