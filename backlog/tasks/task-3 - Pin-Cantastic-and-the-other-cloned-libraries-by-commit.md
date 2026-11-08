---
id: TASK-3
title: Pin Cantastic and the other cloned libraries by commit
status: Done
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:41'
labels:
  - P03
  - ovcs
milestone: m-0
dependencies: []
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The mise `libraries` task clones Cantastic, express_lrs, msp_osd and ovcs_control at their default-branch HEAD. Pin each by commit and fail CI when a clone's HEAD differs from its pin. Later Cantastic changes reach OVCS through an explicit pin bump.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 scripts/libraries.tsv pins every sideloaded library by commit
- [x] #2 mise run libraries clones missing libraries at their pin and leaves existing clones alone
- [x] #3 mise run libraries-check fails CI when a clone is not at its pin
<!-- AC:END -->
