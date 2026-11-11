---
id: TASK-97
title: Find why a stereo pipeline test fails under load
status: To Do
assignee: []
created_date: '2026-11-12 00:30'
labels:
  - vision
dependencies: []
ordinal: 76000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`VisionCore.Stereo.PipelineTest`'s "computing natively stops once the Port fails ten pairs in a row" failed once in a full `vision/core` run while a firmware build loaded the machine, and passed in three runs of its file alone and in the next full run. A test that depends on the machine's load is a race: find it, reproduce it (for example under `stress` or with the scheduler slowed), capture it in a test that fails reliably, then fix the test or the code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The race is identified and reproduced on demand
- [ ] #2 The test passes under load in 20 consecutive runs
<!-- AC:END -->
