---
id: TASK-9
title: Expire the Leaf inverter's torque request when its loop stops
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:10'
labels:
  - P09
  - ovcs
milestone: m-2
dependencies:
  - TASK-7
  - TASK-50
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add VmsCore.ActuatorCommand and use it in the inverter. Test at the boundary on the bench: suspend or stop the component, wait past the deadline, the emitted torque is zero; resume, it recovers. Docs reference the deadline function instead of repeating the number.
<!-- SECTION:DESCRIPTION:END -->
