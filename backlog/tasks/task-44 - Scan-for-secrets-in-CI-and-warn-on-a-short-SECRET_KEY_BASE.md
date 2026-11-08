---
id: TASK-44
title: Scan for secrets in CI and warn on a short SECRET_KEY_BASE
status: Done
assignee: []
created_date: '2026-11-08 10:42'
updated_date: '2026-11-08 12:04'
labels:
  - P44
  - ovcs
milestone: m-6
dependencies: []
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 mise run secrets scans commits with a pinned gitleaks, locally and in CI
- [x] #2 CI scans the commits a pull request or push adds
- [x] #3 A firmware build warns when SECRET_KEY_BASE is shorter than 64 bytes
<!-- AC:END -->
