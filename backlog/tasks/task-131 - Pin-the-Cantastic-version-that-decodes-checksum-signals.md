---
id: TASK-131
title: Pin the Cantastic version that decodes checksum signals
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 14:00'
updated_date: '2026-11-15 18:41'
labels:
  - simulator
  - libraries
dependencies: []
ordinal: 91000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Simulated components receive frames the VMS emits with a `checksum` signal (`vms_torque_request`, `brake_request`), which Cantastic fails to decode before open-vehicle-control-system/cantastic#17. Once it merges, `scripts/libraries.tsv` pins its merge commit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `scripts/libraries.tsv` pins a Cantastic commit that decodes checksum signals
- [x] #2 Every project depending on Cantastic passes its tests on it
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The pin moves from `d8c2d77` to `a38c451`, the merge of #17, whose first parent is the old pin: the change is #17 alone. #16, merged after it, updates Cantastic's own toolchain and test dependencies and can follow in a pin of its own.

A received `checksum` signal used to raise `CaseClauseError`, dropping the frame; it now decodes as an integer, unverified. Emission is unchanged, and on main no topology receives a frame with a checksum signal, so only the simulator's receiving side changes. Against #17, OVCS1's live boot under `--simulate` logged no decode warning in 90 s, where Cantastic `d8c2d77` logged 17,351, with the same `vms_status` sequence and no other new warning.
<!-- SECTION:NOTES:END -->
