---
id: TASK-3
title: Pin Cantastic and the other cloned libraries by commit
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P03
  - ovcs
milestone: m-0
dependencies:
  - TASK-2
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The mise `libraries` task clones Cantastic, express_lrs, msp_osd and ovcs_control at their default-branch HEAD. Pin each by commit and fail CI when a clone's HEAD differs from its pin. Later Cantastic changes reach OVCS through an explicit pin bump.
<!-- SECTION:DESCRIPTION:END -->
