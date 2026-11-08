---
id: TASK-1
title: Mark the EVPT23 charger status frame as extended
status: Done
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:42'
labels:
  - P01
  - ovcs
milestone: m-0
dependencies: []
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cantastic rejects 0x18FF50E5 as a standard id, so the OVCS1 VMS cannot load its topology. Add `extended: true` to both 0x18FF50E5 YAMLs and a test that loads every frame specification. Set `runtime: false` on the cantastic dependency of ovcs_can so plain `mix test` runs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Both 0x18FF50E5 charger status YAMLs are marked extended
- [x] #2 A test loads every shared component frame through Cantastic and fails on the unmarked id
<!-- AC:END -->
