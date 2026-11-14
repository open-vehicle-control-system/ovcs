---
id: TASK-153
title: Write MCAP files from the vision core
status: To Do
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - vision
  - ros2
dependencies: []
ordinal: 106000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 2 of the ROS 2 bag exporter (TASK-151 to TASK-156, design in TASK-151): an Elixir MCAP writer with zstd chunks from OTP, message indexes, summary, attachments and splitting; CPU and throughput measured on the unit with raw stereo.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A bag written by the writer passes mcap doctor and ros2 bag info
- [ ] #2 A file cut off mid-write loses at most its open chunk
- [ ] #3 CPU and MB/s with raw stereo measured on the unit and recorded in the PR
<!-- AC:END -->
