---
id: TASK-136
title: Bring the vision API's remaining routes in line with the HTTP API rules
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T16:28:00Z'
updated_date: '2026-11-13T17:00:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 93000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Four deviations from CODE_STYLING.md's HTTP APIs section remained in vision/api.

Done here: a POST carrying a client id answers 403, where it was accepted and the id ignored; a known route sent another method answers 405 with Allow, where it answered 404.

Still to design and agree, since both change what the dashboard reads:

- POST /api/exporters/:id/actions/:name names the operation in the path and answers 200. Proposed: POST /api/exporter-actions, a document of type exporter-actions with the action's name and parameters in attributes and the exporter as its exporter relationship; 201 with the resource for a JSON result, 200 with the file for a file result.
- The save, discard and reset resources list the parameters they touched as attributes.parameters. Proposed: a parameters to-many relationship.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A POST whose document carries an id answers 403
- [x] #2 A known route sent another method answers 405 with an allow header
- [ ] #3 The exporter action route and the touched parameters follow the agreed design
<!-- AC:END -->
