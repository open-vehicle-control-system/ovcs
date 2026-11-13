---
id: TASK-131
title: Pin the Cantastic version that decodes checksum signals
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
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
- [ ] #1 `scripts/libraries.tsv` pins a Cantastic commit that decodes checksum signals
- [ ] #2 Every project depending on Cantastic passes its tests on it
<!-- AC:END -->
