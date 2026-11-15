---
id: TASK-157
title: Say what brakes on a negative ROS throttle
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T12:00:00Z'
labels:
  - vms
  - ros2
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Three comments on the ROS command frames say a negative throttle is regenerative braking on OVCS1. It is not: the Leaf inverter zeroes a throttle below its threshold, and the iBooster brakes on the negative throttle of the vehicle's `requested_braking_sources`. `RosActuatorCommand.Throttle` and `docs/ros2/commands.md` already say so.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The `0x2B0` frame definition, `RosActuatorCommand.Direction` and `RosVelocityCommand` say a negative throttle brakes, without naming regenerative braking
- [x] #2 No other comment or guide says OVCS1 brakes regeneratively on a negative throttle
<!-- AC:END -->
