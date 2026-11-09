---
id: TASK-57
title: Move the generic stereo stages' computation and kernels to nx_stereo
status: To Do
assignee: []
created_date: '2026-11-08 19:47'
labels:
  - vision
  - refactor
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
vision_core's stereo stages mix generic stereo algorithms with OVCS-specific measurements. Rectification, matching and depth compute in nx_stereo, but the speckle filter (OpenCV filterSpeckles' role), the temporal filter and the point cloud unprojection (which nx_stereo's Depth.cloud_grid nearly duplicates) are computed in vision_core, and so are the Vulkan kernels of all of them, rectification and depth included. Moving the generic computation and its kernels to nx_stereo, next to sgm's shaders, would leave vision_core with each stage's wrapper (settings, dashboard text, finish) and the OVCS measurements (Sharpness, RowAlignment, Quality). The native Rust implementations in stereo_match stay in OVCS and keep their parity tests against the Nx code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 NxStereo.Rectify.rectify/3 and NxStereo.Depth.depth/3 run hand-written Vulkan kernels when compiled for Vulkan, as NxStereo.sgm/3 does, and vision_core no longer carries those kernels
- [ ] #2 The speckle filter, temporal filter and point cloud computation, with their kernels, are nx_stereo functions; their vision_core stages call them
- [ ] #3 Sharpness, RowAlignment and Quality and their kernels stay in vision_core
- [ ] #4 stereo_match's parity tests and vision_core's kernel tests (--include vulkan) pass, and the VENTUNO Q board gives the same results as before the move
- [ ] #5 The nx_stereo changes are pushed to Spin42/nx_stereo and vision_core pins that version
<!-- AC:END -->
