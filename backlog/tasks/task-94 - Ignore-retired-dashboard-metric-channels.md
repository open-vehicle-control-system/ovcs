---
id: TASK-94
title: Ignore retired dashboard metric channels
status: In Progress
assignee:
  - Codex
created_date: '2026-11-12 23:00'
labels:
  - vms
  - dashboard
dependencies: []
---

## Description

Metric channel callbacks mutate shared connection state even after their listener is replaced. A late close or error from the old channel marks the new one unjoined and silently drops subscriptions. Old updates can overwrite the replacement channel's metrics.

## Acceptance Criteria

- [x] A retired channel cannot change current connection readiness or metrics.
- [x] A replacement channel subscribes only after its own join succeeds.
- [x] Existing reconnect and subscription reference-count behavior remains covered.
- [x] Dashboard tests and production build pass.

## Design

Guard every asynchronous callback with the channel identity and reset readiness when replacing a listener. Invalidate the current listener before leaving it so synchronous close callbacks are harmless. Preserve the existing single-channel store.
