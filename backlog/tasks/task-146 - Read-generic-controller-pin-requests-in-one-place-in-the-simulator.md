---
id: TASK-146
title: Read generic controller pin requests in one place in the simulator
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 10:00'
labels:
  - simulator
dependencies: []
ordinal: 100000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The simulated generic controller, Leaf inverter, iBooster and steering column each build the name of a controller's digital pin request frame and of its pin signals, and each decode a pin from the frame. A pure module owns the frame's naming and decoding, and the four read the request through it, so a simulated part wired to a controller's pin does not repeat the controller's frame layout.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One module names a controller's digital pin request frame and its pin signals, and decodes a pin from it, tested
- [x] #2 The simulated generic controller, inverter, iBooster and steering column read pin requests through it, their tests unchanged
<!-- AC:END -->
