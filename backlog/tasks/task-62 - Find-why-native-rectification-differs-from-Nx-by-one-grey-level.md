---
id: TASK-62
title: Find why native rectification differs from Nx by one grey level
status: In Progress
assignee:
  - '@claude'
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
- [x] #1 The pixel's sample position and its bilinear value are traced in both implementations, and the operation that differs is named
- [x] #2 Either the native code computes it as the Nx code does, and the parity test checks rectification exactly again, or the difference is shown to be inherent and documented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The pixel is (16, 34) of the left image. Its map_y is 34.01978302 natively and on Nx's evaluator, and 34.01977921, one ulp lower, in the test's reference; the bilinear value is then 38.50036 (39) natively and just under 38.5 (38) in the reference.

The reference was not the evaluator: the segment is built with `compiler: Nx.Defn.Evaluator`, but `Rectify.rectify/3` is an `Nx.block`, whose Nx code runs on the global default compiler, EXLA in `test_helper.exs`. EXLA's CPU code fuses multiply-adds: emulating `r2 = fma(x, x, y * y)` and `map_y = fma(fy, yd, cy)` reproduces its map_y on all 3072 pixels, while every other operation rounds as the evaluator and stereo_match do. The same frame on the evaluator as default compiler gives 39, as native does.

The parity test now makes its compiler the global default while it runs both segments, and checks rectification exactly on both pairs. The native code was already right.
<!-- SECTION:NOTES:END -->
