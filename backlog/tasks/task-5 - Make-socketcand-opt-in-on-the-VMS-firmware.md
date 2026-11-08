---
id: TASK-5
title: Make socketcand opt-in on the VMS firmware
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P05
  - ovcs
milestone: m-0
dependencies: []
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
socketcand off unless enabled in .env.exs (SOCKETCAND_ONLY still enables it). Log a warning at boot when it is on, so a bench image is noticed.
<!-- SECTION:DESCRIPTION:END -->
