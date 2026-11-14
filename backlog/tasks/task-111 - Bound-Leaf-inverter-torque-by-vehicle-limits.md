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

- [x] Positive requests cannot exceed the configured torque magnitude in either gear.
- [x] Negative requests, the deadband, neutral and parking preserve their existing zero-torque behavior.
- [x] Pure boundary tests and a real disabled Cantastic emitter verify the result.
- [x] Core formatting, compilation, strict Credo and tests pass.

## Design

Extract the torque decision unchanged first, then saturate its normalized input using the existing NormalisedRequest contract. Enforce the limit in the actuator regardless of which source the manager selects. Command expiry and braking remain separate requirements.

## Validation

The unchanged extraction passes all 257 baseline core tests. Three of the five new tests fail before saturation, including 240 Nm requested against a 120 Nm limit at the real emitter boundary. With saturation, all 262 core tests, formatting, compilation with warnings-as-errors and strict Credo pass. No CAN frame is transmitted.
