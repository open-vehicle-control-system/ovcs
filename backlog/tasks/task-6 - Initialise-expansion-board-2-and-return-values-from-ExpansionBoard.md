---
id: TASK-6
title: Initialise expansion board 2 and return values from ExpansionBoard
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P06
  - controllers
milestone: m-0
dependencies: []
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configuration.cpp sets the board 1 flag for board 2, so board 2 is never initialised. ExpansionBoard::begin() and lastError() return no value (undefined behaviour).
<!-- SECTION:DESCRIPTION:END -->
