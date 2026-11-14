---
id: TASK-91
title: Keep the VMS heartbeat in reset mode
status: In Progress
assignee:
  - Codex
created_date: '2026-11-12 23:00'
labels:
  - vms
  - safety
dependencies: []
---

## Description

While reset mode is active, the heartbeat alternates between RESETTING and the vehicle status every loop. The second condition restores the vehicle status as soon as the first condition has emitted RESETTING.

## Acceptance Criteria

- [x] Every loop during reset keeps the heartbeat in RESETTING.
- [x] Leaving reset restores the latest vehicle status, including FAILURE.
- [x] A regression exercises consecutive loops with a real Cantastic emitter.
- [x] Core checks pass.

## Design

Extract the existing status decision into a pure module in a behavior-preserving commit. Then make reset mode dominate vehicle status until reset ends. This preserves the existing reset command and timing; redesigning automatic rearming remains TASK-20.

## Validation

Two regressions reproduced the alternating status before the fix. The real emitter test keeps transmission disabled. Formatting, compilation with warnings as errors, strict Credo and 260 core tests pass.
