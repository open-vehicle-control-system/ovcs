# Bridge Firmware

Shared Nerves firmware image that hosts a vehicle's extensions next to
the `ovcs` bus: one or more [`OvcsBridge`](../../libraries/ovcs_bridge)
libraries, such as `RadioControlBridge` and `RosBridge`, plus any other
child an entry lists (the OVCS Mini runs its bus gateway this way). A
vehicle declares what each image runs, and on which Nerves target, via
its `bridge_firmwares/0` callback — one Nerves image per entry.

See [`docs/vehicle_package.md`](../../docs/vehicle_package.md#bridge-firmwares)
for the boot flow and [`libraries/ovcs_bridge/README.md`](../../libraries/ovcs_bridge/README.md)
for the supervision contract.

## Targets

The `mix.exs` target-gates the bridge libraries it pulls in:

| Target | Typical use |
|--------|-------------|
| `:ovcs_base_can_system_rpi3a` | A Pi 3A running the radio control bridge |
| `:ovcs_base_can_system_rpi4` | A Pi 4 running the ROS bridge |
| `:rpi5` | A Pi 5 running the ROS bridge, perception included (system `ovcs_bridges_system_rpi5`) |

Custom Nerves systems live in their own repos under
[`open-vehicle-control-system`](https://github.com/open-vehicle-control-system).

## Building

Preferred, from the repo root:

```sh
./ovcs build  <vehicle> <bridge_firmware_id>   # e.g. ovcs1 radio_control
./ovcs burn   <vehicle> <bridge_firmware_id>
./ovcs upload <vehicle> <bridge_firmware_id> [--host HOST]
./ovcs clean  <vehicle> <bridge_firmware_id>
```

`<bridge_firmware_id>` is a key in the active vehicle's
`bridge_firmwares/0` map (e.g. `radio_control`, `ros`). The CLI resolves
the target from that entry, sets `VEHICLE` + `BRIDGE_FIRMWARE_ID` +
`MIX_TARGET`, and delegates to `build.sh` / `burn.sh` / `upload.sh` /
`clean.sh` in this directory.

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module name |
| `BRIDGE_FIRMWARE_ID` | yes | Key in the vehicle's `bridge_firmwares/0` map |
| `MIX_TARGET` | no | Nerves target (default resolved from the `bridge_firmwares/0` entry) |

`AUTHORIZED_SSH_KEYS`, `SECRET_KEY_BASE`, `SIGNING_SALT`, etc. live in
`vehicles/<vehicle>/.env.exs` (gitignored, shared across vms /
infotainment / bridges).

## How it boots

`BridgeFirmware.Application` starts `OvcsBridge.Supervisor`, which:

1. Reads `VEHICLE` + `BRIDGE_FIRMWARE_ID` from app env.
2. Calls `vehicle.bridge_firmwares()[firmware_id]` to find the bundled bridge modules.
3. Starts `OvcsBus.Cluster` so this BEAM joins the vehicle's distributed Erlang mesh.
4. Flat-maps `children/0` from every bundled bridge and supervises them under `:one_for_one`.
