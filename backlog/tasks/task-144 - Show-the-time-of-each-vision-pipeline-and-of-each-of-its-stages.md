---
id: TASK-144
title: Show the time of each vision pipeline and of each of its stages
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-14T00:18:00Z'
updated_date: '2026-11-14T00:26:00Z'
labels:
  - vision
dependencies: []
ordinal: 100000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The dashboard menu shows a duration only under the NPU inference stages. Every stage should carry its time, and each pipeline its total, so that the cost of a pipeline reads where its stages are listed.

Design: the status snapshot gains pipelines, by pipeline name: total_ms, the work per pair or frame (the sum of its stages, without queueing or the wait for a stereo pair), stages, the mean time of each stage timed alone, and segments, the runs of stages a compiled segment fuses, each with its one time. Means are taken over the status tick, nil for a tick without a pair or frame. The stereo pipeline's times come from Pair.stage_ms, which it already measures; the detection and segmentation pipelines read the clock around each of their steps and answer the sums at the tick, as the inference backends do. An inference stage's time is its wall time, submit to reply; the accelerator's own time stays beside it. A fused run shows its one time once, on its first stage, as covering the run: dividing it would invent figures, and separating it needs a device synchronisation per stage.

Options considered: times on GET /api/stages (rejected: polled, and the status channel already carries the accelerator time); latency as the stereo total (rejected: it includes queueing and the hold for the next pair).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each stage of each pipeline shows its time in the menu
- [ ] #2 Each pipeline shows its total time
- [ ] #3 Measuring adds no stage synchronisation the pipeline did not already have
<!-- AC:END -->
