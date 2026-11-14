---
id: TASK-141
title: Keep every calibration made on the vision unit, named and selectable
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-14T00:04:00Z'
updated_date: '2026-11-14T00:54:00Z'
labels:
  - vision
dependencies: []
ordinal: 97000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A calibration applied from the dashboard or committed by cameracalibrator replaces the stored YAML files, and the one before is lost. The unit should keep each calibration it was given, let it be named, and let any of them be put back in force.

Design (proposed, to agree before implementation):

Storage, in the unit's SQLite database (VisionCore.Repo), as columns, not serialized documents:
- calibrations: id, target (the calibrations collection id, such as stereo or center), name, origin (dashboard or cameracalibrator), board_columns, board_rows, board_square_m, samples, stereo_rms_px, baseline_m, rectified_fx_px, inserted_at.
- calibration_cameras: calibration_id, name (left, right or the camera's), image_width, image_height, fx, fy, cx, cy, k1, k2, p1, p2, k3, rms_px, and the rectification (r00..r22) and projection (p00..p23) matrices one column per element.
- calibration_selections: target (unique), calibration_id, null for the firmware's.

The YAML files of the store directory stay what the pipelines and the ROS 2 exporter read: selecting a calibration writes them from its rows through the existing commit path, so nothing downstream changes. A recorder process follows each change a target's calibration publishes and the unit's start: a stored calibration the library does not hold is kept, as dashboard with the session's figures when a session announced it, as imported otherwise (one committed by cameracalibrator, or stored before the library existed), and the one in the store is selected. Selecting a kept calibration commits its figures through the existing commit path, so nothing downstream changes.

API, on the HTTP API rules: saved-calibrations (GET collection filtered by calibration, GET one, PATCH name, DELETE one not in force), and POST /api/calibration-selections naming a saved calibration, 202 as an apply; calibration-resets stays the selection of the firmware's.

Dashboard: under the calibration in force, the list of the target's calibrations with name (editable), date, errors and baseline, the one in force marked, Use and Delete on the others, the firmware's as a fixed first row.

Options considered: one JSON or YAML column per calibration (rejected: not queryable, and the figures the list shows would be parsed on every read); keeping only files, one directory per calibration (rejected: names and the selection need a second store anyway).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A calibration applied from the dashboard is kept with its board, views and errors
- [ ] #2 A calibration committed by cameracalibrator is kept
- [ ] #3 A kept calibration can be renamed, put back in force and, when not in force, deleted, over the API and from the page
- [ ] #4 The calibration in force survives a restart and a firmware upload
- [ ] #5 Calibrations are stored as typed columns, with no serialized document
<!-- AC:END -->
