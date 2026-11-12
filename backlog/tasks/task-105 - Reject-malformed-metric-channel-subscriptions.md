---
id: TASK-105
title: Reject malformed metric channel subscriptions
status: To Do
priority: medium
labels: [vms, review]
dependencies: []
---

MetricsChannel raises for unknown atom names and malformed payloads. Both failures were reproduced through channel callbacks; unsubscribing a valid but absent metric is already idempotent and should remain so.

## Acceptance Criteria

- [ ] Unknown and malformed subscriptions return an error without crashing the channel.
- [ ] Unsubscribing an absent metric is idempotent.
- [ ] Subscriptions are bounded and only refer to permitted metric identifiers.

## Design

Validate payload shape and resolve identifiers without raising or creating atoms. Keep subscription maps and timers consistent after every rejection; authentication remains TASK40.
