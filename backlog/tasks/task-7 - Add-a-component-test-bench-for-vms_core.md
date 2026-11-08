---
id: TASK-7
title: Add a component test bench for vms_core
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:10'
labels:
  - P07
  - ovcs
milestone: m-1
dependencies:
  - TASK-49
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cut VmsCore.Test.Bench from the component-tests work, with the review fixes: round-trip every sent and received frame through the YAML specification; run the real ReceivedFrameWatcher instead of delivering missing-frame events the component never enabled; wait with assert_receive instead of Process.sleep. First user: the ABS tests.

CODE_STYLING.md forbids tests that mock Cantastic; reword that rule to admit a stand-in that encodes and decodes through the real frame specification.
<!-- SECTION:DESCRIPTION:END -->
