---
id: TASK-62
title: Find why native rectification differs from Nx by one grey level
status: To Do
assignee: []
created_date: '2026-11-10 20:00'
labels:
  - vision
dependencies:
  - TASK-61
ordinal: 57000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
nx_stereo's native rectification is meant to give the Nx code's results exactly, with the same f32 operations in the same order. On a 64x48 pair (NxStereo.NativeParityTest's second pair: seed 2, radial distortion 0.02, a right row offset of 0.5), one pixel of 3072 in the left image differs by one grey level from both Nx's evaluator and EXLA, while the first pair matches exactly. The parity test allows one level for now. The cause, presumably a sample on a rounding half computed in another order or precision, is not known.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The pixel's sample position and its bilinear value are traced in both implementations, and the operation that differs is named
- [ ] #2 Either the native code computes it as the Nx code does, and the parity test checks rectification exactly again, or the difference is shown to be inherent and documented
<!-- AC:END -->
