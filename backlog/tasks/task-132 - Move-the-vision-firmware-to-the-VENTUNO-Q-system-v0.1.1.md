---
id: TASK-132
title: Move the vision firmware to the VENTUNO Q system v0.1.1
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T16:07:00Z'
updated_date: '2026-11-13T17:13:00Z'
labels: []
dependencies: []
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
vision/firmware pins nerves_system_arduino_ventuno_q at v0.1.0. The v0.1.1 system lets the center camera start after a reboot without the firmware-path workaround.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 vision/firmware depends on nerves_system_arduino_ventuno_q v0.1.1
- [x] #2 The firmware builds for arduino_ventuno_q and uploads to the board
- [x] #3 After a reboot without the firmware-path workaround, the center camera starts at 30 fps
<!-- AC:END -->
