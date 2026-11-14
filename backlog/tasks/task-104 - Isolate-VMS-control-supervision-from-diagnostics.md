---
id: TASK-104
title: Isolate VMS control supervision from diagnostics
status: To Do
priority: high
labels: [vms, review]
dependencies: []
---

NetworkInterfaces, Metrics, Repo and vehicle control children share one one_for_one supervisor and its restart budget. PR309 removes one reproducible diagnostic crash, but unrelated diagnostics failures can still terminate control children.

## Acceptance Criteria

- [ ] Repeated diagnostic worker failures do not restart safety control processes.
- [ ] Every restarted control process starts with an explicitly safe command.
- [ ] Tests inject diagnostic failures while observing real disabled CAN emitters.

## Design

Introduce separate supervision subtrees and document restart behavior. Pair isolation with command expiry (TASK9–18), since a healthy emitter must not keep a dead control loop effective.
