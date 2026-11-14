---
id: TASK-107
title: Expose metric and channel freshness in the dashboard
status: To Do
priority: medium
labels: [vms, review]
dependencies: []
---

Metrics retains the last value indefinitely and payloads do not include sample age. LiveContent marks socket disconnection, but a stopped producer or failed metric channel can leave old values looking current while the socket remains connected.

## Acceptance Criteria

- [ ] The UI distinguishes fresh, stale and unavailable source data.
- [ ] Source stalls and channel-only failures are covered separately from socket loss.
- [ ] Measurement age is not refreshed by retransmitting a cached value.

## Design

Carry sample validity/age from producers through the metrics API and track channel health in the dashboard. Define freshness semantics per metric instead of treating every loop broadcast as a new measurement.
