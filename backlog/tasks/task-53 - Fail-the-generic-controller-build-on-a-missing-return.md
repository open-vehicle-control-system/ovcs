---
id: TASK-53
title: Fail the generic controller build on a missing return
status: To Do
assignee: []
created_date: '2026-11-08 18:50'
labels:
  - controllers
milestone: m-7
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Renesas Arduino framework compiles with -w, which also silences -Werror=return-type. Lift -w for the generic controller's own code only (the framework and third-party libraries print about 790 warnings without it), fix the warnings that appear there, and make return-type an error.
<!-- SECTION:DESCRIPTION:END -->
