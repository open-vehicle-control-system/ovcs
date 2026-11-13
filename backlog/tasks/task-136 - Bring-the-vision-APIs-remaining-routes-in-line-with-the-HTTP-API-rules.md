---
id: TASK-136
title: Bring the vision API's remaining routes in line with the HTTP API rules
status: To Do
assignee: []
created_date: '2026-11-13T16:28:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 93000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Four deviations from CODE_STYLING.md's HTTP APIs section remain in vision/api: POST /api/exporters/:id/actions/:name names the operation in the path and answers 200; the save, discard and reset resources list the parameters they touched as attributes.parameters, not as a relationship; a POST carrying a client id is accepted and the id ignored, where JSON:API asks for a 403; a known route with an unsupported method answers 404, not 405 with Allow.

Design to agree before implementation: the exporter action's route and document shape (for example POST /api/exporter-actions with the exporter as a relationship and the action's name as an attribute), since it and the relationship change both change what the dashboard reads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Design agreed and recorded in this task
<!-- AC:END -->
