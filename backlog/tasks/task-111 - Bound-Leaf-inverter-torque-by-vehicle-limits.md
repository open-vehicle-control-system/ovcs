---
id: TASK-111
title: Bound Leaf inverter torque by vehicle limits
status: In Progress
assignee: [Codex]
created_date: '2026-11-13 00:58'
labels: [vms, safety]
dependencies: []
---

The inverter multiplies a request by the configured drive/reverse torque limit without bounding the request. The ROS command CAN field represents values above one, so a value of two requests twice the configured maximum.

## Acceptance Criteria

- [ ] Positive requests cannot exceed the configured torque magnitude in either gear.
- [ ] Negative requests, the deadband, neutral and parking preserve their existing zero-torque behavior.
- [ ] Pure boundary tests and a real disabled Cantastic emitter verify the result.
- [ ] Core formatting, compilation, strict Credo and tests pass.

## Design

Extract the torque decision unchanged first, then saturate its normalized input using the existing NormalisedRequest contract. Enforce the limit in the actuator regardless of which source the manager selects. Command expiry and braking remain separate requirements.
