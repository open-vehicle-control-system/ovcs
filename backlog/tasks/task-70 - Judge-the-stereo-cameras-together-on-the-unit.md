---
id: TASK-70
title: Judge the stereo cameras together on the unit
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 17:00'
labels:
  - vision
dependencies: []
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision dashboard showed the cameras' synchronisation, row alignment and sharpness as signed numbers and a right-to-left ratio, and judged them itself, so it did not say which camera was at fault or what to do, and the row correction the unit applies, which can hide a calibration that no longer fits, was not shown at all.

Chosen: the unit judges. `VisionCore.Stereo.PairCheck` checks a status window's `timing`, `rows`, the automatic row correction included, and `focus`: each check has a level, the camera it points at, issue codes, a gauge placing it against its threshold toward the camera it concerns, and its figures with their direction worked out. The thresholds and the issue codes are its constants. `VisionCore.Status` adds the checks to its snapshot as `pair`, and each camera's issues; the status channel sends them with no text. The dashboard maps each code to its wording, draws each check between the previews as its value, a cursor on a track from the left camera to the right one, and a short detail, and badges and rings the frame of a camera with something to do, computing nothing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `PairCheck` judges timing, rows and focus with named thresholds and issue codes, pointing each warning at a camera
- [x] #2 The status snapshot and channel carry the checks and each camera's issues, documented in the API guide with every issue code
- [x] #3 The dashboard shows each check's figures and issues and each camera's issues, from a constant map of the codes, without thresholds of its own
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
An issue raised past its threshold clears only below 0.8 of it: on the Arduino VENTUNO Q the rows' band spread sat at 0.95 to 1.03 rows and the warning came and went every second. Every part of a check keeps its size, and the badges and the ring are drawn over the frame, so a warning coming or going moves nothing on the page.
<!-- SECTION:NOTES:END -->
