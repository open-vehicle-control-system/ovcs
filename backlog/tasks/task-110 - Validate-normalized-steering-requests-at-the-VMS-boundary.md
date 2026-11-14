---
id: TASK-110
title: Validate normalized steering requests at the VMS boundary
status: To Do
priority: medium
labels: [vms, review]
dependencies: []
---

The ROS steering CAN field can represent roughly +/-32.768, but RosActuatorCommand.Steering forwards it unchanged despite the [-1,1] contract. Traxxas clamps physical travel, while VehicleMotion scales the unbounded request into its reported angle.

## Acceptance Criteria

- [ ] Out-of-contract steering values have an explicit VMS-side refusal or saturation policy.
- [ ] Actuation and reported steering angle use the same validated request.
- [ ] Boundary tests cover the full representable CAN range and source changes.

## Design

Validate commands in pure code at the VMS boundary. Preserve the deliberate hold-last-steering behavior on link loss while preventing unbounded targets and inconsistent odometry.
