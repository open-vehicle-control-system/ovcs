---
id: TASK-99
title: Reopen a QNN Port that failed to reopen
status: To Do
assignee: []
created_date: '2026-11-12 09:30'
labels:
  - vision
dependencies:
  - TASK-92
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The detection and segmentation QNN backends reopen their Port after it exits, but when that reopen fails they schedule no further attempt: the pipeline stays without inference until the backend restarts. Retry with a backoff, and share the Port's lifecycle between the two backends, which today duplicate it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A backend whose Port fails to reopen retries with a bounded backoff until it opens, logging once per failure streak
- [ ] #2 Detection and segmentation use one implementation of the QNN Port's lifecycle
<!-- AC:END -->
