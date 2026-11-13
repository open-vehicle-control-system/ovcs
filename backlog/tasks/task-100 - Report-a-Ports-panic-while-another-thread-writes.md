---
id: TASK-100
title: Report a Port's panic while another thread writes
status: In Progress
assignee: []
created_date: '2026-11-12 10:00'
labels:
  - vision
dependencies:
  - TASK-94
ordinal: 79000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`framing::Writer::log_panics` sends a panic's message as a log record only when it gets the stdout lock at once; it skips it when another thread holds the lock, and with `panic = "abort"` the host then sees only the exit status (the Ports' stderr is not read). `v4l2_capture`'s single mode writes frames on a writer thread that holds the lock for each ~12 ms write, so a panic during conversion loses its message about half the time.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A panic while another thread holds stdout still reaches the host as a log record, after a bounded wait for the lock
- [x] #2 A test panics while another thread holds the writer and finds the record
<!-- AC:END -->
