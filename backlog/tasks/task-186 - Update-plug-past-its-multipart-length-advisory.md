---
id: TASK-186
title: Update plug past its multipart length advisory
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T12:40:00Z'
labels:
  - ci
  - security
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`mix hex.audit` fails every CI job of the eleven projects that lock `plug` 1.20.3, on `main` and on every pull request that runs them: EEF-CVE-2026-120287 (GHSA-qj4r-jh2r-rw3f, medium), `Plug.Parsers.MULTIPART` not charging part and header framing to its `:length` limit. `plug` 1.20.4 fixes it; each project's lock moves to it with `mix deps.update plug`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No project locks `plug` 1.20.3
- [x] #2 `mix hex.audit` passes in each project that locked it
- [x] #3 Each of those projects compiles without warnings and passes `mix test --no-start`, as CI runs it
<!-- AC:END -->
