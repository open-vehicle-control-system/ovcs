---
id: TASK-59
title: Share the detection backends' Port handling
status: To Do
assignee: []
created_date: '2026-11-09 19:35'
labels: []
dependencies: []
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
VisionCore.Detection.Backend.Hailo and .Qnn carry the same Port machinery: the request and reply records, the in-flight frame and its timeout, the reopen backoff and the log records. Extract it into one module both use, keeping each backend's model loading, arguments and environment its own.
<!-- SECTION:DESCRIPTION:END -->
