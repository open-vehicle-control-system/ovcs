---
id: TASK-157
title: Cap the stereo unit's rate
status: In Progress
assignee: []
created_date: '2026-11-14T23:04:00Z'
labels:
  - vision
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On the OVCS Mini the native stereo matcher takes about 188 % of the Pi 5's 4 cores at about 23 Hz, the cameras fall to 26-28 fps and frames reach the unit 135 ms late. A `max_hz` on the stereo unit drops pairs before matching above that rate, so a skipped pair costs no matching. Detection follows the stereo pairs, so it runs at the same rate. Options considered: fewer SGM paths or disparities (worse depth; 48 disparities moves the nearest distance from 0.53 m to 0.71 m on the Mini), running the matcher at a lower priority (frees no CPU), detection on every pair with depth on fewer (rectifies pairs it does not match; larger change). Chosen: the cap, 15 Hz on the Mini.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A stereo unit with max_hz matches at most that many pairs per second, dropping the others before stereo_match
- [ ] #2 Without max_hz nothing changes
- [ ] #3 The OVCS Mini's stereo unit runs at 15 Hz; its cameras, latency and CPU are measured before and after on the unit
<!-- AC:END -->
