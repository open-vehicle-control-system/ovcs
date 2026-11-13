---
id: TASK-134
title: Set the depth colour range through a JSON:API resource
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T16:28:00Z'
updated_date: '2026-11-13T16:40:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 91000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The depth video's colour range is written by a depth_range push on the preview:depth channel: the only write outside the JSON:API resources.

Design: a depth-previews singleton, GET and PATCH /api/depth-preview, whose colourRangeM attribute is VisionCore.Preview's depth range. PATCH sets it; a value Preview refuses is a 422, and both answer 503 while the previews do not run. The channel takes no depth_range push; it keeps pushing the depth_range event after a join and on every change, the live notice of the resource to every dashboard. The range stays a view setting of the unit: not saved, back to the composer's at the next boot.

Options considered: a vision parameter (it would be saved, counted as unsaved and listed as a pipeline step, where it is a view setting on purpose); keeping the channel write (stays outside JSON:API).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 GET /api/depth-preview answers the depth-previews resource with colourRangeM
- [x] #2 PATCH /api/depth-preview sets it: 200, 422 for a refused value, 409 and 400 for a malformed document, 503 while the previews do not run
- [x] #3 preview:depth takes no depth_range push and still pushes the depth_range event
- [x] #4 The dashboard's depth range control sets it with PATCH
- [x] #5 docs/vision/api.md, docs/vision/channels.md and vision/api/README.md match
<!-- AC:END -->
