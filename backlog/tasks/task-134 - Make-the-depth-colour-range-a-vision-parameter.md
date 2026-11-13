---
id: TASK-134
title: Make the depth colour range a vision parameter
status: To Do
assignee: []
created_date: '2026-11-13T16:28:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 91000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The depth video's colour range is written by a depth_range push on the preview:depth channel: the only write outside the JSON:API resources. It is the unit's state but no parameter: absent from /api/parameters, not saved, not resettable, not settable from ROS 2, and /api/configuration keeps showing its start value.

Design: VisionCore.Preview declares a parameter group with one live double parameter, the range in metres (0 to 50, as set_options accepts today), applied through the registry like the other live parameters. The channel's depth_range push and event go; the dashboard's DepthRange sets it with PATCH /api/parameters/:id and reads it from the parameters store, which already polls. Behaviour change: a change is unsaved until saved, survives a reboot once saved, and is settable from ROS 2.

Options considered: a dedicated previews resource with PATCH (a second way to hold unit state next to the parameters); keeping the channel write (stays outside JSON:API).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The depth colour range is a parameter listed by /api/parameters and set with PATCH
- [ ] #2 preview:depth takes no depth_range push and pushes no depth_range event
- [ ] #3 The dashboard's depth range control sets and shows the parameter
- [ ] #4 docs/vision/api.md, docs/vision/channels.md and vision/api/README.md match
<!-- AC:END -->
