---
id: TASK-140
title: Simulate the Volkswagen Polo 9N ignition lock
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 22:52'
labels:
  - simulator
dependencies:
  - TASK-121
ordinal: 94000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1 reads its ignition key from the Polo 9N ignition lock on `key_status` (0x570): `VmsCore.Components.Volkswagen.Polo9N.IgnitionLock` publishes `:contact`, and OVCS1 is ready to drive only once the key has been turned to start. Nothing simulates the lock, so OVCS1 cannot reach ready to drive in simulation (TASK-127).

Options:
1. Wait for scenarios (TASK-124) and make the key a scenario input only: OVCS1 waits on a larger piece of work.
2. A simulated ignition lock whose key follows a script, as `SimulatorCore.SimulatedComponents.OVCS.RadioControl` scripts the radio: its clock starts when the VMS sends `vms_status` and rewinds when the VMS goes quiet.

Chosen: 2. TASK-124 later drives the key from a scenario instead of the script, as it does the radio. The script repeats the radio's clock rather than sharing it, since TASK-124 replaces both.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.IgnitionLock reports the key off at the start, then each scripted position from the VMS's first vms_status, and rewinds to off when the VMS goes quiet
- [x] #2 key_status emits with a simulated definition that has a frequency and reads back through the shared one as the VMS receives it: off, on and start
- [x] #3 simulator/core tests pass, with format, credo, dialyzer and warnings as errors
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
`key_status` emits with `volkswagen/polo_9n/simulated/0x570_key_status.yml`: the shared definition has no frequency, which Cantastic needs to emit a frame, and maps several bytes to `contact_on`. The simulated one gives one byte per key state, at 10 Hz, a rate not measured on the Polo 9N.
<!-- SECTION:NOTES:END -->
