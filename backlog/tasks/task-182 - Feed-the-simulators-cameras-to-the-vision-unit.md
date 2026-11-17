---
id: TASK-182
title: Feed the simulator's cameras to the vision unit
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - simulator
  - vision
dependencies:
  - TASK-129
ordinal: 122000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision unit's camera drivers read real sensors only, so nothing in the perception stack runs against a simulator. Godot renders the vehicle pack's stereo pair and sends each image over the simulator link (`image`: `camera`, `time_s`, `format`, the encoded image as the body).

Add a camera driver that takes the simulator's left and right images as the stereo unit's pair, so stereo depth, `<prefix>/points` and the pipelines downstream run on the host as they do on the vehicle. Its calibration comes from the vehicle pack's pinhole intrinsics and baseline (for the OVCS Mini: 480×270, fx 379.03, 90 mm), not from a calibration session. How the images reach the vision unit's BEAM from the runner's (Erlang distribution, or a link connection of the vision unit's own) is decided here before code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A vision unit started against the simulator pairs Godot's left and right images and computes depth from them, tested on recorded images
- [ ] #2 The stereo unit's calibration is the vehicle pack's, with no calibration session
- [ ] #3 `<prefix>/points` against Godot places a known obstacle at its distance in the simulated world, within a tolerance a check states
- [ ] #4 A simulator that disconnects and reconnects leaves the vision unit running; it reports the cameras absent until images return
<!-- AC:END -->
