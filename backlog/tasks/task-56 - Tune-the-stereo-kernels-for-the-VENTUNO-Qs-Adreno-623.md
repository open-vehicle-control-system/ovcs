---
id: TASK-56
title: Tune the stereo kernels for the VENTUNO Q's Adreno 623
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08 19:36'
updated_date: '2026-11-09 10:57'
labels:
  - vision
  - performance
dependencies: []
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On the Arduino VENTUNO Q, OVCS1's stereo runs every stage as hand-written Vulkan kernels. At a 364x272 matching size with 128 disparities a pair takes 90-150 ms, nearly all of it in nx_stereo's libSGM-derived matching shaders; the stages after matching take about 7 ms. The matching shaders were written for other GPUs and have not been tuned for the Adreno 623 (subgroup size 128, 32 KB shared memory).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A pair at 364x272 with 128 disparities takes measurably less time on the board than before, with the same matches as EXLA
- [ ] #2 The matching at 728x544 is measured on the board, to decide whether the full sensor width is usable
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured on the board (728x544, 128 disparities, 8 paths unless stated; all exact vs EXLA):
- IREE's Vulkan allocator recycles 64 MiB slabs only; a call's transients are packed into one allocation, allocated and freed every call beyond that (~0.26 ms/MB). A 512 MiB slab (local nx_iree patch, not yet an option) took matching from 290 to 199 ms.
- Adreno 623 reads ~25 GB/s only when consecutive lanes read consecutive 32-bit words; per-lane vector loads ~8 GB/s. CPU on the same DDR: 31 GB/s read, 43 GB/s write. GPU ceiling ~25 GB/s at 877 MHz.
- IR3 assembly (VK_KHR_pipeline_executable_properties): native shfl; readonly SSBO loads are isam, a uvec2 load is two 32-bit fetches; a shuffle whose source lane differs per pixel is very slow (32 ms of the selection).
- nx_stereo branch perf/adreno-matching: vertical scan split from the selection, paired scans (selection reads 4 volumes), subpixel neighbours by OR reduction, selection tiles through shared memory, relative shuffles, block 4 option: matching 211 -> 127 ms.
- vision_core: params and entries on the device, outputs in one download: 480x270x64x3 ~15 ms per pair (was ~50), 364x272x128x8 ~36 ms, 728x544x128x8 ~137 ms (matching-bound).
- The board's CPU (native stereo_match): 728x544x128x8 70 ms.
- 30 FPS at 728x544x128 with 8-path SGM is out of reach on this GPU (memory-bound); coarse-to-fine is TASK-58.
<!-- SECTION:NOTES:END -->
