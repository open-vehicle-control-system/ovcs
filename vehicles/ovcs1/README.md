# OVCS1

Vehicle package for **OVCS1** — the full-size platform, a 2007 Volkswagen
Polo converted to an electric vehicle with a Nissan Leaf AZE0 drivetrain,
Bosch iBooster Gen2, Orion BMS2, and custom OVCS controllers.

This directory is a standalone Mix app implementing the
[`OvcsVehicle`](../../libraries/ovcs_vehicle) behaviour. Select it with
`VEHICLE=Ovcs1` (or pass `ovcs1` to the `ovcs` CLI).

## What this package contributes

| Side | Composer | Nerves target |
|------|----------|---------------|
| VMS | `Ovcs1.Vms.Composer` | `:ovcs_base_can_system_rpi4` |
| Infotainment | `Ovcs1.Infotainment.Composer` | `:ovcs_base_can_system_rpi5` |
| Radio-control bridge | `RadioControlBridge` | `:ovcs_base_can_system_rpi3a` |
| ROS bridge | `RosBridge` | `:ovcs_base_can_system_rpi4` |

The VMS side wires every Polo / Leaf / iBooster / BMS / Orion / OVCS
component driver under one supervision tree. The infotainment side
renders the in-car touchscreen pages on the RPi 5 head unit. Both
bridges are opt-in per build (one Nerves image per `bridge_firmwares/0`
entry).

## Quick start

See the [main README](../../README.md#quick-start) and
[Getting Started](../../docs/getting_started.md). In short:

```sh
../../ovcs run ovcs1                     # provision vcan + spawn one BEAM per firmware
../../ovcs attach ovcs1                  # split-pane log + IEx TUI (another terminal)
../../ovcs build ovcs1 vms               # build VMS firmware
../../ovcs build ovcs1 infotainment
../../ovcs build ovcs1 radio_control
../../ovcs build ovcs1 ros
```

Before the first build, copy `.env.exs.example` to `.env.exs` and fill
in your SSH public key(s), Wi-Fi credentials, and Phoenix secrets. The
file is gitignored and shared by every firmware of this vehicle.

## Layout

```
lib/ovcs1.ex                       — OvcsVehicle impl (composers, targets, bridge_firmwares)
lib/ovcs1/vms/                     — VMS-side GenServer + composer + dashboard pages
lib/ovcs1/infotainment/            — Infotainment-side composer + pages
priv/can/vms.yml                   — VMS CAN topology
priv/can/infotainment.yml          — Infotainment CAN topology
priv/can/generic_controller/       — Per-controller frame wirings (front, rear, controls)
priv/firmware/{vms,infotainment,bridges}/  — Per-side fwup overrides
```

## Hardware reference

See [`WIRING.md`](./WIRING.md) for harness-level pin notes. The full
vehicle topology (CAN buses, controllers) is in
[`docs/hardware_architecture.md`](../../docs/hardware_architecture.md).
