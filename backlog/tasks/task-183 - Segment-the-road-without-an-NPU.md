---
id: TASK-183
title: Segment the road without an NPU
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - simulator
  - vision
dependencies:
  - TASK-182
  - TASK-92
ordinal: 123000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Road segmentation (TASK-92) runs on the Hexagon or the Hailo-8; on the host, no backend infers, so against the simulator no pipeline publishes `<name>/labels`, `<name>/road/points` or `<name>/off_road/points`. The design is agreed here before code.

Options:

| Option | What runs | Tests the model | Cost |
|---|---|---|---|
| Ground truth from the simulator | Godot renders a label image beside each colour image and sends it over the link; a backend publishes it as the pipeline's labels | No | One more image a frame; every class exact |
| The model on the CPU | FFNet-122NS-LowRes or DDRNet23-Slim through `nx_iree` llvm_cpu or ONNX Runtime | Yes, on rendered images | A CPU backend; frames a second to measure |

Proposed: ground truth first, so the costmap and the road following (TASK-184, TASK-185) are built against exact labels; the model on the CPU next, to measure its errors on rendered images against that ground truth. Either way, the pipeline's reprojection, clouds and ROS 2 topics are those of TASK-92, unchanged.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The chosen option and the reasons are recorded here before code
- [ ] #2 Against Godot, a segmentation pipeline publishes `<name>/labels`, `<name>/road/points` and `<name>/off_road/points` from the simulator's images
- [ ] #3 The off-road cloud matches the simulated track's edges within a tolerance a check states
<!-- AC:END -->
