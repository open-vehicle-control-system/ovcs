---
id: TASK-50
title: Check the safety-relevant code boundary in CI
status: To Do
assignee: []
created_date: '2026-11-08 11:10'
updated_date: '2026-11-08 11:11'
labels:
  - P46
  - ovcs
  - process
milestone: m-1
dependencies:
  - TASK-49
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a CI check (custom credo check or mix xref script) that safety-relevant modules do not depend on non-safety ones. It reads the safety-relevant path list from one configuration file, and CODE_STYLING.md points at that file instead of repeating the list. It starts with an exclusion list of today's violations; a module leaves the list when it is cleaned.
<!-- SECTION:DESCRIPTION:END -->
