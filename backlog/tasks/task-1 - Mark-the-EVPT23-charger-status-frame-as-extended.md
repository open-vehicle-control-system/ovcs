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
Cantastic rejects 0x18FF50E5 as a standard id, so the OVCS1 VMS cannot load its topology. Add `extended: true` to both 0x18FF50E5 YAMLs, and a test in each reference vehicle that loads its firmwares' topologies through Cantastic as at boot, each frame in the direction the topology uses it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Both 0x18FF50E5 charger status YAMLs are marked extended
- [x] #2 Each reference vehicle has a test that loads its VMS and infotainment topologies through Cantastic
- [x] #3 OVCS1's test fails on the unmarked id
<!-- AC:END -->
