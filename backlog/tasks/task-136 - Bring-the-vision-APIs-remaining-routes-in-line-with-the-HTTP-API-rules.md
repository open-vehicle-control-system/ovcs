---
id: TASK-136
title: Bring the vision API's remaining routes in line with the HTTP API rules
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T16:28:00Z'
updated_date: '2026-11-14T01:04:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 93000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Four deviations from CODE_STYLING.md's HTTP APIs section remained in vision/api.

Done here: a POST carrying a client id answers 403, where it was accepted and the id ignored; a known route sent another method answers 405 with Allow, where it answered 404.

Still to agree, since both change what the dashboard and the docs read:

1. Exporter actions. POST /api/exporters/:id/actions/:name names the operation in the path and answers 200.

   Recommended: POST /api/exporter-actions with a document of type exporter-actions, the action's name and its parameters in attributes, and the exporter as its exporter relationship. It answers 201 with the action resource and the action's JSON result in attributes.result; an action whose result is a file answers 201 with the resource and a links.download to GET /api/exporter-actions/:id/file, which serves the file once. A client id is a 403, an unknown exporter or action a 404 with a pointer, a refused action a 422.

   Why: the rule book has state changes as resources created with POST, never verbs in a path, and one media type per route; today the same route answers JSON or a file by content. Cost: the debug exporter's export download becomes two requests, and the unit must hold the file between them (one per action, dropped when read or after a minute).

   Alternative: keep one request for a file result, answering 200 with the file and no resource. It keeps the download simple and breaks the one-media-type rule for that outcome only.

2. Touched parameters. The save, discard and reset resources list the parameters they touched as attributes.parameters, an array of ids.

   Recommended: a parameters to-many relationship, {data: [{type: parameters, id}]}, and include=parameters to get their new state in the same answer.

   Why: ids of other resources are relationships in JSON:API, and include lets the dashboard drop the refetch it does after each save. Cost: a small change in the dashboard's parameters service and in docs/vision/api.md.

Both are contained in vision/api, the dashboard's services and the API guide.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A POST whose document carries an id answers 403
- [x] #2 A known route sent another method answers 405 with an allow header
- [ ] #3 The exporter action route and the touched parameters follow the agreed design
<!-- AC:END -->
