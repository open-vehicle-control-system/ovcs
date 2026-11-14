---
id: TASK-109
title: Gate steering actuation on fresh valid feedback
status: To Do
priority: high
labels: [vms, review]
dependencies: []
---

SteeringColumn records sensor_ready, calibration_valid and trimming_valid but does not use them to enable automatic mode. There is no LWS sample deadline; a stored angle can continue driving the PID after feedback disappears.

## Acceptance Criteria

- [ ] Automatic steering requires fresh, valid LWS feedback.
- [ ] Missing or invalid feedback causes the defined safe actuation and readiness response.
- [ ] Tests inject each flag failure and a stalled feedback producer.

## Design

Extract a pure steering enable decision and set its timeout in the vehicle composer. Establish the relay/PWM safe sequence on the bench; coordinate TASK14/15.
