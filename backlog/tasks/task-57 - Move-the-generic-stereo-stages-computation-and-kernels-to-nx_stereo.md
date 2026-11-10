---
id: TASK-57
title: Move the stereo stages' computation and kernels to nx_stereo
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08 19:47'
updated_date: '2026-11-10 11:00'
labels:
  - vision
  - refactor
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The stereo pipeline's GPU code is split between two repositories. nx_stereo holds the matcher and its shaders; vision_core holds the Vulkan kernels of every other stage (rectification, speckle filter, temporal filter, depth, point cloud, and the sharpness, row alignment and quality measurements) and the computation of those that have no nx_stereo function. Profiling or optimising the whole pipeline therefore means working across both repositories, with a lock bump and a firmware build between a shader change and its measurement, and the per-kernel profiling of the full pipeline exists in no repository.

Every one of these computations is a generic stereo operation rather than OVCS logic: rectification, depth and the point cloud already have Nx code in nx_stereo; the speckle and temporal filters are standard disparity post-processing; sharpness (focus comparison of the two cameras), row alignment (rectification drift) and quality (match ratio, disparity statistics, jitter) are diagnostics any stereo rig needs. Moving all of them, with their kernels and a committed device benchmark of the full pipeline, to nx_stereo puts every stereo shader in one place and lets an optimisation round run there; vision_core keeps each stage's wrapper (settings, checks, dashboard text, logging, finish) and the live check on the board. The native Rust implementations in stereo_match stay in OVCS and keep their parity tests against the Nx code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The design below is agreed before implementation starts
- [ ] #2 NxStereo.Rectify.rectify/3, NxStereo.Depth.depth/3 and the point cloud run hand-written Vulkan kernels when compiled for Vulkan, as NxStereo.sgm/3 does, including frames packed as 32-bit words for a GPU without 8-bit storage
- [ ] #3 The speckle filter and the temporal filter, with their kernels, are nx_stereo functions
- [ ] #4 Sharpness, row alignment and disparity statistics, with their kernels, are nx_stereo functions returning finished measures; vision_core keeps only their thresholds, wording and reporting
- [ ] #5 vision_core carries no shader, SPIR-V or kernel module; its stages call nx_stereo
- [ ] #6 nx_stereo has a committed benchmark that runs the full stereo pipeline (rectify, match, filters, depth, point cloud, diagnostics) on a Vulkan device, reports each stage's time (each Nx.block compiled alone, less an empty call's) and checks the results against the Nx code
- [ ] #7 stereo_match's parity tests, nx_stereo's and vision_core's suites (--include vulkan) pass, and the VENTUNO Q board gives the same results and depth rate as before the move
- [ ] #8 The nx_stereo changes are merged into Spin42/nx_stereo and vision_core pins that version
- [ ] #9 The scripts that hot-load a build on the VENTUNO Q and time its segment are committed in OVCS
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design, to be agreed before implementation.

Options considered:
- A. Move only the generic filters and depth; keep sharpness, row alignment and quality in vision_core. Leaves four shaders and a kernel module in OVCS, so the pipeline still spans two repositories.
- B. Move everything, generalising the measurements (chosen). One place for every stereo shader and for profiling; costs a public diagnostics API in nx_stereo, each device function plain Nx wrapped in an Nx.block whose Vulkan implementation is the kernel, the Nx code being the default and the test reference. Settings that change while running are tensors, stacked into one params input as sgm/3's penalties. Values a kernel compiles in (the despeckle radius, the temporal filter's missed-count cap, row alignment's bands, reach and row step) are options with those values as defaults; other values run the Nx code.
- NxStereo.Packing: pack/3 and unpack_download/1 on the host, unpack/2 and pack_image/1 in a compiled function: images packed four 8-bit pixels to a 32-bit word, for a GPU without 8-bit storage (from VisionCore.Stereo.Packing).
- NxStereo.Rectify.rectify/3 runs its kernel on u8 frames whose output width is a multiple of 4; NxStereo.Rectify.rectify_packed/3 takes a packed u32 frame and returns the s32 image and its packing.
- NxStereo.Depth.depth/3: metres and u16 millimetres, the millimetres 0 beyond 65535 mm (no depth, as vision_core gives today, instead of saturating).
- NxStereo.Depth.point_cloud/5 (depth_m, focal_length_px, cx, cy, opts: :decimation, :min_depth_m, :max_depth_m) returns the grid of every decimation-th pixel from the first, NaN outside the range, and the number of points kept. It replaces cloud_grid/5, whose sampling disagreed with its own coordinates when the size is not a multiple of the decimation and which gave 0, 0, 0 for no depth.
- NxStereo.Filter.despeckle/2 (:min_support, :max_diff, :radius) and NxStereo.Filter.temporal/4 (current, previous, missed; :alpha, :delta, :hold) returning the filtered disparity and the missed counts.
- NxStereo.Diagnostics, each measure in two parts, because the sums are taken in the compiled function and turned into measures after download: sharpness_sums/2 and sharpness/1 (per image, mean squared horizontal-neighbour difference over the squared mean grey, black pixels excluded); row_alignment_sums/4 (:bands, :reach, :row_step) and row_alignment/2 (:min_matched; the sub-row offset over the image and per band, nil where too few pixels matched or the minimum is not unique); disparity_sums/2 and disparity_stats/2 (matched fraction, mean and spread of the disparity, jitter against the previous map).

Benchmark: bench/pipeline.exs runs the chain at a given size on a Vulkan device (--device), times each stage compiled alone less an empty call's time, and the whole chain, and counts pixels differing from the Nx code. Per-kernel times within a stage need a Vulkan-level tool outside NxIREE and stay out of scope.

Steps (separate PRs):
1. nx_stereo: Packing, rectify/depth/point cloud kernels, filters, with tests against Nx on Vulkan.
2. nx_stereo: Diagnostics with their kernels and tests.
3. nx_stereo: bench/pipeline.exs and a README section on profiling.
4. OVCS: vision_core stages call nx_stereo, their native_constants read from nx_stereo's defaults; Kernels, Packing, shaders and the shaders mix task removed; the board scripts committed; lock bump; board check against the current firmware's results and rate.

Starts after nx_stereo#2 and the VENTUNO Q PR merge.
<!-- SECTION:PLAN:END -->
