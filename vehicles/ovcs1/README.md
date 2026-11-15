# OVCS1

Vehicle package for **OVCS1** — the full-size platform, a 2007 Volkswagen
Polo converted to an electric vehicle with a Nissan Leaf AZE0 drivetrain,
Bosch iBooster Gen2, Orion BMS2, and custom OVCS controllers.

This directory is a standalone Mix app implementing the
[`OvcsVehicle`](https://github.com/open-vehicle-control-system/ovcs/tree/main/libraries/ovcs_vehicle) behaviour. Select it with
`VEHICLE=Ovcs1` (or pass `ovcs1` to the `ovcs` CLI).

## What this package contributes

| Side | Composer or bridges | Nerves target |
|------|---------------------|---------------|
| VMS | `Ovcs1.Vms.Composer` | `:ovcs_base_can_system_rpi4` |
| Infotainment | `Ovcs1.Infotainment.Composer` | `:ovcs_base_can_system_rpi5` |
| Bridge firmware `radio_control` | `RadioControlBridge` | `:ovcs_base_can_system_rpi3a` |
| Bridge firmware `ros` | `RosBridge` | `:ovcs_base_can_system_rpi4` |

The VMS side wires every Polo / Leaf / iBooster / BMS / Orion / OVCS
component driver under one supervision tree. The infotainment side
renders the in-car touchscreen pages on the RPi 5 head unit. Both
bridges are opt-in per build (one Nerves image per `bridge_firmwares/0`
entry).

## Quick start

See the [main README](https://github.com/open-vehicle-control-system/ovcs#quick-start) and
[Setup](https://ovcs.be/docs/getting-started). In short, with the `ovcs` CLI on your `PATH`:

```sh
ovcs run ovcs1                     # provision vcan + spawn one BEAM per firmware
ovcs attach ovcs1                  # split-pane log + IEx TUI (another terminal)
ovcs build ovcs1 vms               # build VMS firmware
ovcs build ovcs1 infotainment
ovcs build ovcs1 bridge-radio_control
ovcs build ovcs1 bridge-ros
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

## Simulation

`Ovcs1.simulator/0` declares the simulated hardware the simulator runner runs: the three generic controllers, the Polo 9N ABS and ignition lock, the Leaf AZE0 inverter, the iBooster Gen2, the steering column and the radio, with their frames in `priv/can/simulator.yml`. Controllers, pins, networks and radio channels come from `Ovcs1.Vms.Composer.wiring/0`. The Orion BMS2 and the EVPT charger are not simulated, so the pack status reports the BMS as not alive.

The key turns to start a second after the VMS's first `vms_status`, then back to on, and the radio stays at `:manual`.

None of the physical parameters is measured on OVCS1:

| Parameter | Value | Source |
|---|---|---|
| Wheelbase | 2.46 m | Polo 9N specification, `Ovcs1.geometry/0` |
| Wheel radius | 0.289 m | 185/60 R14 tyre, `Ovcs1.geometry/0` |
| Maximum speed | 25 m/s | estimate |
| Mass | 1,300 kg | estimate: a Polo 9N's kerb weight with the conversion |
| Pack voltage | 360 V | estimate: a Leaf 24 kWh pack's nominal voltage |
| Reduction ratio | 3.300 × 3.389 | Polo 02R gearbox (code HGW) specification: first gear times the final drive. The Leaf motor drives it through a coupling, with no Leaf reducer, and the simulation holds first gear. |
| Steering ratio | 17 | estimate |
| Steps per column degree | 100 | estimate |
| Column end stop | 520° either side | estimate |
| iBooster rod speed | 100 mm/s | estimate |
| iBooster full-travel deceleration | 8 m/s² | estimate |

## Hardware reference

See [`WIRING.md`](./WIRING.md) for harness-level pin notes. The full
vehicle topology (CAN buses, controllers) is in
[`docs/hardware.md`](https://ovcs.be/docs/hardware).
