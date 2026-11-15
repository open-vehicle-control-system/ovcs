---
id: TASK-158
title: Finish aligning the vision code with the conventions
status: To Do
assignee: []
created_date: '2026-11-15T00:10:00Z'
labels:
  - vision
  - conventions
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Findings of the vision conventions audit left for after the open PRs (#358, #359, the disks PR), which change the files they are in: singular names for VisionCore.Settings, Options, StageTimes, Components, Pipelines, Ros2.ZenohExporter.Detections and .Diagnostics (decide each: a set or one thing); ExporterController building the API's output list itself; params in Exporter.handle_action/4, Runner.action/4, Exporters.action/4; one word per idea for pose and position, apply/commit/put in use, Parameters.Group and stages, board (chessboard and the computer), remove and delete, settings/parameters/options; refusals tested on one route only: 406, non-JSON body, 405, sort and include on writes, calibration-cancels 409, the DELETE saved-calibration task exit. Settled and kept: 'stored' is the calibration files on disk, 'saved' the database rows.
<!-- SECTION:DESCRIPTION:END -->
