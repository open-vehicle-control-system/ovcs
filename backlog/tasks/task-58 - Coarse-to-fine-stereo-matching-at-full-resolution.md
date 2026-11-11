---
id: TASK-58
title: Coarse-to-fine stereo matching at full resolution
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-09 10:57'
updated_date: '2026-11-09 11:56'
labels:
  - vision
  - performance
dependencies:
  - TASK-56
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Matching 728x544 with 128 disparities at 30 FPS on the VENTUNO Q's GPU: full-resolution 8-path SGM moves ~1 GB per pair through a ~25 GB/s memory port (137 ms per pair). Coarse-to-fine matches a 2x-shrunk pair over the full range, then refines at full resolution over a narrow band of disparities per pixel around the upscaled coarse result: ~1/8 of the full-resolution cost volume, same range, 8-path smoothness, full-resolution precision. Known trade-off: structures too thin to survive the 2x shrink (poles, cables) can get the background's disparity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 NxStereo.sgm_band/4 with a band covering the full range gives exactly NxStereo.sgm/3
- [x] #2 The band SGM's Vulkan shaders give the Nx reference's matches on a Vulkan GPU
- [x] #3 On Middlebury pairs, coarse-to-fine agrees with full-resolution SGM within 1 px on at least 95% of the pixels both match, and its error against ground truth is reported beside SGM's
- [x] #4 vision_core's Disparity stage takes mode: :coarse_to_fine, documented in the stages guide
- [x] #5 On the VENTUNO Q, the default stages at 728x544 with 128 disparities in coarse-to-fine mode run at 30 pairs a second or the measured rate is reported with what limits it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design:
1. Shrink the rectified pair 2x; SGM over 64 disparities (= 128 at full resolution), today's shaders.
2. Per full-resolution pixel, a band of B candidates starting at 2 x the minimum coarse disparity of its 3x3 neighbourhood, minus R (B 16, R 4 to start), clamped to [0, 128 - B]; unmatched coarse pixels stay unmatched.
3. SGM over the band volume (W x H x B): census costs, 8 paths with the neighbours' bands aligned by absolute disparity (a candidate outside the neighbour's band takes the P2 path), winner, subpixel, uniqueness, left-right consistency, median.

PRs, each its own commit set:
0. Land the VENTUNO Q GPU work (vision_core kernels and transfers, nx_stereo perf/adreno-matching, the IREE slab size as an option, the GPU clock).
1. nx_stereo: NxStereo.sgm_band/4 as Nx, and the 2x shrink; a full-range band gives exactly sgm/3.
2. nx_stereo: Vulkan shaders for the band SGM, exact vs the Nx reference on a Vulkan GPU.
3. nx_stereo: sgm_coarse_to_fine/3; quality vs full-resolution SGM and ground truth (Middlebury), tuning B, R and the coarse paths.
4. vision_core: Disparity mode: :coarse_to_fine; docs.
5. OVCS1: 728x544 coarse-to-fine; measured on the board and real camera images.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Steps 1-3 done in nx_stereo (local branch perf/adreno-matching): sgm_band/4 (Nx + Vulkan shaders, a thread per line, costs from census features, no cost volume; negative base = no estimate), sgm_coarse_to_fine/3 (2x shrink, sgm/3 at 64 disparities, band base = 2 x the coarse 3x3 minimum - margin). Host Intel GPU: shaders match the Nx reference.
Middlebury 2006 half size (6 scenes, 128 disparities, P1 8, P2 64; bad1 = matched pixels > 1 px from ground truth):
| Scene | full SGM bad1 | c2f band 16 bad1 | half-res SGM x2 bad1 | c2f agreement with full SGM, band 16 / 32 |
| Aloe | 5.9 | 8.3 | 13.1 | 96.8 / 98.1 |
| Baby1 | 5.5 | 6.1 | 8.9 | 98.8 / 99.3 |
| Cloth1 | 0.5 | 0.6 | 1.4 | 99.8 / 100 |
| Lampshade1 | 10.9 | 12.0 | 17.9 | 97.3 / 98.1 |
| Bowling1 | 12.7 | 13.8 | 18.7 | 96.0 / 97.5 |
| Flowerpots | 11.1 | 12.1 | 19.7 | 96.9 / 98.4 |
Band 8 (margin 2) falls to 93.9% agreement on Bowling1; 3 coarse paths cost about 1 point of bad1. Defaults: band 16, margin 4, coarse paths = paths. Board timing not measured (board unavailable).

Step 4 done: vision_core Disparity search: "coarse_to_fine" (02421897), documented in docs/vision/performance.md and basics.md. Step 5 (OVCS1 at 728x544 coarse-to-fine, measured on the board with real camera images) waits for the board and for OVCS1's camera tasks (CAMSS routing, v4l2_capture 10-bit, stereo component).
Board (VENTUNO Q, GPU pinned at 877 MHz, 512 MiB Vulkan slabs, 728x544, 128 disparities, results equal to EXLA's in every case). The first band shaders took 9-12 ms per scan direction: each step loaded every candidate's census and indexed its band dynamically (scratch memory). nx_stereo now computes the band's costs once (band_cost.comp), keeps each line's band in registers (a barrel shifter over constant indices, loads one step ahead), runs the horizontal scans over a column-major copy of the costs with the reverse scan adding the forward one, and selects a lane per word of the band.
| Matching alone | ms |
| full SGM, 8 paths | 126-131 |
| c2f band 16, coarse 3 paths, fine 8 | 40.2 (97.7 before the shader work) |
| c2f band 16, coarse 8, fine 8 | 52.1 |
| c2f band 16, coarse 3, fine 3 | 33-36 |
| c2f band 8, coarse 3, fine 8 | 32.0 |
| c2f band 8, coarse 3, fine 3 | 29.5 |
| c2f band 32, coarse 3, fine 8 | 78.8 (registers) |
Default stages, whole pipeline per pair: search coarse_to_fine 8 paths 57.5 ms (17/s, was 116 ms), 3 paths 38 ms (26/s); full search 8 paths 135 ms.
What limits it (band 16, 8 paths, per kernel): coarse matching at 364x272 (3 paths 9.9 ms, 8 paths 17.4 ms), census 3.8, band costs 4.2, horizontal scans with their transpositions 7.5, the six other scans 7.5, selection 2.7, consistency 1.7, median 0.5; the stages around the matching about 10 ms. Each scan step is a chain of dependent loads and arithmetic on few waves, so scans are latency-bound, not bandwidth-bound. The Disparity stage passes no coarse_paths, so coarse-to-fine uses 8 coarse paths; 3 would save about 12 ms a pair at about 1 point of bad1.
<!-- SECTION:NOTES:END -->
