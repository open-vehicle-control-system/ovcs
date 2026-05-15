# OVCS Mini

Vehicle package for **OVCS Mini** — a Traxxas 4WD RC car running the full
OVCS software/hardware stack. Used for safe development and testing of
radio-control and ROS2 features before deploying to OVCS1.

This directory is a standalone Mix app implementing the
[`OvcsVehicle`](../../libraries/ovcs_vehicle) behaviour. Select it with
`VEHICLE=OvcsMini` (or pass `ovcs_mini` to the `ovcs` CLI).

OVCS Mini has **no infotainment side** — there's no head unit on the RC
car. The `infotainment/0` callback is omitted, so the infotainment
firmware is never built for this vehicle.

## What this package contributes

| Side | Composer | Nerves target |
|------|----------|---------------|
| VMS | `OvcsMini.Vms.Composer` | `:ovcs_base_can_system_rpi4` |
| Radio-control bridge | `RadioControlBridge` | `:ovcs_base_can_system_rpi3a` |
| ROS bridge | `RosBridge` | `:ovcs_base_can_system_rpi4` |

A single `ovcs` CAN bus carries everything (no third-party automotive
components needing isolation).

## Quick start

```sh
../../ovcs run ovcs_mini                 # provision vcan + spawn VMS + bridge BEAMs
../../ovcs attach ovcs_mini
../../ovcs build ovcs_mini vms
../../ovcs build ovcs_mini radio_control
../../ovcs build ovcs_mini ros
```

Before the first build, copy `.env.exs.example` to `.env.exs` (gitignored).

## Layout

```
lib/ovcs_mini.ex                   — OvcsVehicle impl
lib/ovcs_mini/vms/                 — VMS-side composer + dashboard pages
priv/can/vms.yml                   — VMS CAN topology (single `ovcs` bus)
priv/can/generic_controller/       — Per-controller frame wirings
priv/firmware/{vms,bridges}/       — Per-side fwup overrides
```

See [`docs/hardware_architecture.md`](../../docs/hardware_architecture.md#ovcs-mini-hardware)
for the RC-car hardware breakdown.
