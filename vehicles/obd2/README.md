# OBD2

Vehicle package for **OBD2 diagnostic mode** — turns any OBD-II-equipped
car into an OVCS host for reading standard OBD2 PIDs over the diagnostic
plug. Useful for sanity-checking the OVCS stack against a real vehicle
without an OVCS-specific harness.

This directory is a standalone Mix app implementing the
[`OvcsVehicle`](../../libraries/ovcs_vehicle) behaviour. Select it with
`VEHICLE=Obd2` (or pass `obd2` to the `ovcs` CLI).

## What this package contributes

| Side | Composer | Nerves target |
|------|----------|---------------|
| VMS | `Obd2.Vms.Composer` | `:ovcs_base_can_system_rpi4` |
| Infotainment | `Obd2.Infotainment.Composer` | `:ovcs_base_can_system_rpi5` |

No bridges. The VMS-side CAN topology issues OBD2 requests (see
`priv/can/vms.yml`) and decodes the responses; the infotainment side
renders them on the head unit.

## Quick start

```sh
../../ovcs run obd2                      # provision vcan + spawn VMS + infotainment BEAMs
../../ovcs attach obd2
../../ovcs build obd2 vms
../../ovcs build obd2 infotainment
```

Before the first build, copy `.env.exs.example` to `.env.exs` (gitignored).

## Layout

```
lib/obd2.ex                        — OvcsVehicle impl
lib/obd2/vms/                      — VMS-side composer + OBD2 request handling
lib/obd2/infotainment/             — Infotainment-side composer + pages
priv/can/vms.yml                   — OBD2 request definitions
priv/can/infotainment.yml          — Infotainment CAN topology
priv/firmware/{vms,infotainment}/  — Per-side fwup overrides
```

See [`libraries/cantastic/README.md`](../../libraries/cantastic/README.md#obd2-request-definitions)
for the OBD2 request YAML schema.
