---
id: TASK-100
title: Align OVCS1 ROS authority across its actuators
status: To Do
priority: high
labels: [vms, review]
dependencies: []
---

OVCS1 wires ROS teleop propulsion, steering and direction, but SteeringColumn and IBoosterGen2 enable automatic actuation only for :radio. ROS propulsion can therefore be selected without the requested steering or service braking.

## Acceptance Criteria

- [ ] A declared control level requires a complete supported actuator capability set.
- [ ] ROS selection is inhibited until its steering and braking path is validated.
- [ ] Tests cover every configured level and loss of an actuator capability.

## Design

Introduce a pure authority/capability decision at the VMS boundary. Decide explicitly whether OVCS1 ROS is supported before enabling additional actuators; exercise the agreed behavior on a bench.
