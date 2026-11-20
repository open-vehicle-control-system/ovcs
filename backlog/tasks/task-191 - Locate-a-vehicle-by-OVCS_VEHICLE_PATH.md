---
id: TASK-191
title: Locate a vehicle by OVCS_VEHICLE_PATH
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-19T22:00:00Z'
labels:
  - cli
  - firmware
dependencies:
  - TASK-190
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every firmware, `OvcsVehicle.Firmware`, `compose/local` and the CLI find a vehicle at `vehicles/<dir>` of the OVCS checkout, so a vehicle kept in its own repository cannot be built.

`OVCS_VEHICLE_PATH` names the vehicle package's folder; each of them uses it when set and falls back to `vehicles/<dir>` otherwise. The CLI sets it for every command it runs. `scripts/libraries.sh sync` moves clean sideloaded clones to their pins, for an OVCS checkout nobody edits, such as a vehicle's `deps/ovcs`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With `OVCS_VEHICLE_PATH` set, every firmware, `OvcsVehicle.Firmware`, `compose/local` and the CLI use the vehicle there
- [x] #2 Without it, each falls back to `vehicles/<dir>` exactly as before
- [x] #3 `scripts/libraries.sh sync` moves clean clones to their pins and refuses dirty ones
<!-- AC:END -->
