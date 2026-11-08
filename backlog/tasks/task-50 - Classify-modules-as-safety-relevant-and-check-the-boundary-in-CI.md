---
id: TASK-50
title: Classify modules as safety-relevant and check the boundary in CI
status: To Do
assignee: []
created_date: '2026-11-08 11:10'
updated_date: '2026-11-08 11:33'
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
Add `@moduledoc safety: :relevant` or `safety: :none` to every module in vms_core and in each vehicle's vms.ex and vms/. Add a script in scripts/, run in CI like check_docs.exs, that fails when a module in those paths has no declaration and prints the list of safety-relevant modules. A second check uses that list to fail when a safety-relevant module depends on a non-safety one, starting with an exclusion list of today's violations; a module leaves the list when it is cleaned. CODE_STYLING.md then links to the script.
<!-- SECTION:DESCRIPTION:END -->
