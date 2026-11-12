---
id: TASK-106
title: Return not found for unknown dashboard pages
status: To Do
priority: medium
labels: [vms, review]
dependencies: []
---

BlocksController dereferences pages[page_id].blocks without checking the lookup. An unknown page raises BadMapError. Dashboard configuration is also optional in the vehicle behavior.

## Acceptance Criteria

- [ ] Unknown page IDs return 404.
- [ ] A vehicle without dashboard configuration has a defined empty/not-found response.
- [ ] Controller tests cover both cases.

## Design

Handle unavailable configuration and absent page lookup at the API boundary before rendering.
