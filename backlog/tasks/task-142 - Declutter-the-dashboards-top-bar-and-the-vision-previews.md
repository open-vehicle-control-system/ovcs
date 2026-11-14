---
id: TASK-142
title: Declutter the dashboards' top bar and the vision previews
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-14T00:06:00Z'
updated_date: '2026-11-14T00:26:00Z'
labels:
  - dashboard
dependencies: []
ordinal: 98000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The shared top bar lists every interface, the load averages, the version and the system at all times and wraps on common widths; the vision previews cannot be enlarged, their warning ring sits on the card's border, and the asides beside them float mid-card.

Design: the top bar keeps the vehicle, CPU, memory in use (new: memoryPercent on GET /api/board, from /proc/meminfo) and clock, and opens the rest from a button; the board's figures go once the unit is disconnected, as its clock is then unknown. Each preview gets a full-screen button, its frame is inset from the card, and its aside is pinned to the card's edge. The parameter panel's How it works toggle takes a line of its own.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The top bar shows vehicle, CPU, memory and clock, and the rest on demand
- [ ] #2 GET /api/board carries memoryPercent on the vision and VMS APIs
- [ ] #3 A disconnected unit shows no ticking clock
- [ ] #4 A preview can be shown full screen, overlays included
<!-- AC:END -->
