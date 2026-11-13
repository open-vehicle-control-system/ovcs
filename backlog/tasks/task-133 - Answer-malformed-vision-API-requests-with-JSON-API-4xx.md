---
id: TASK-133
title: Answer malformed vision API requests with JSON:API 4xx
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T16:24:00Z'
updated_date: '2026-11-13T16:28:00Z'
labels: []
dependencies: []
ordinal: 90000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CODE_STYLING.md gains the HTTP APIs rules. Four requests break them in vision/api: a parameter reset whose relationships are malformed resets every parameter; PATCH /api/parameters/:id with a body that is not JSON answers 500; include[]= on /api/stages and /api/ros2-node answers 500; a malformed JSON body (400) and an unacceptable Accept (406) are answered as application/json; charset=utf-8, without a detail.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 CODE_STYLING.md states the HTTP API rules: RESTful routes, status codes, JSON:API documents, writes, untrusted input, tests
- [x] #2 POST /api/parameter-resets with a relationships member that is not a well-formed target answers 400 and resets nothing; without relationships it resets every parameter
- [x] #3 PATCH /api/parameters/:id with a form or text/plain body answers 400
- [x] #4 An include that is not a string answers 400 on /api/stages and /api/ros2-node
- [x] #5 A malformed JSON body answers 400 and an unacceptable Accept 406, both as application/vnd.api+json with a detail; a 500 carries no detail
- [x] #6 docs/vision/api.md and vision/api/README.md match
<!-- AC:END -->
