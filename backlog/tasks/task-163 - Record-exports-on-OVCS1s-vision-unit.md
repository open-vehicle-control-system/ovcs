---
id: TASK-163
title: Record exports on OVCS1's vision unit
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T09:46:00Z'
updated_date: '2026-11-15T09:47:00Z'
labels:
  - vision
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's vision composer lists no debug exporter, so its dashboard offers no export to tune its stereo unit with, unlike the OVCS Mini's. List VisionCore.Debug.Exporter among its exporters.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OVCS1's target configuration lists VisionCore.Debug.Exporter, whose check passes and whose outputs the configuration produces
<!-- AC:END -->
