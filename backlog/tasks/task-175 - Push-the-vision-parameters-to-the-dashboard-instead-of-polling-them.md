---
id: TASK-175
title: Push the vision parameters to the dashboard instead of polling them
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T19:56:00Z'
updated_date: '2026-11-15T19:57:00Z'
labels:
  - vision
  - dashboard
dependencies: []
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Each open dashboard tab reloads every vision parameter once a second (stores/parameters.js startPolling, from App.jsx, whether or not the menu shows them). A listing reads all 61 values of the 18 groups, each in a short-lived process calling into its owner: about 12 ms and 48 k reductions on the OVCS Mini. With 6 dashboard connections the registry was the BEAM's busiest process (211 k reductions/s, 241 reaped processes/s), and the unit's reductions rose from about 1.15 M/s to 1.88 M/s, slowing the cameras and the depth on a memory-bound Pi 5.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 VisionCore.Parameters publishes the full listing, once for every subscriber, after each change it makes: a declaration, a component gone, a set, save, discard, reset or forget
- [x] #2 It re-reads the parameters set automatically and the groups' statuses at most once a second, only while a client listens, and publishes the groups whose listing changed
- [x] #3 The dashboard socket's parameters channel pushes the listing on join and each published change, in the shape of GET /api/stages?include=parameters
- [x] #4 The dashboard follows the channel and no longer polls; an idle tab costs the unit nothing
- [x] #5 On the Mini, the unit's reductions with dashboards open are measured before and after
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Pushed, not polled: the registry knows each change it makes, so it publishes one listing for all subscribers (Outputs key {:parameters, :changed}), coalesced over 100 ms. Values that change outside it (applies {:auto, _}: exposure, gain, right_row_offset; group statuses: row alignment) come from hardware readings and measurements that move every frame, in several owners: rather than each owner reporting and rate-limiting itself, the registry re-reads only those groups once a second while a subscriber exists and publishes the ones that differ from what it published last. Rejected: owners calling Parameters.changed/1 (every current and future owner must remember, and throttle per frame); polling last_change and reloading on change (still one request per tab per second, and misses the automatic values). The channel pushes VisionApiWeb.StageJSON's document, meta.complete false for a partial one; edits stay HTTP.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
On the OVCS Mini, detection and segmentation every fifth frame, depth at 20 pairs a second, dashboards open:

| | Polling | Channel |
|---|---|---|
| BEAM reductions | 1.86 M/s | 1.14 M/s |
| VisionCore.Parameters reductions | 200 k/s | 35 k/s |
| Processes the registry reaps | 211/s | 30/s |
| Stage listings over HTTP | 4/s | 0 |

What remains is the once-a-second re-read of the groups with a status or an automatic parameter, the cameras' mostly, while a client is joined.
<!-- SECTION:NOTES:END -->

