---
id: TASK-137
title: Steer and brake OVCS1 under the ros control level
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 13:30'
labels:
  - vms
  - ovcs1
dependencies: []
ordinal: 97000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Under `:ros`, OVCS1's steering column and iBooster stay idle: both compare the selected control level to `:radio`. The Leaf inverter turns a throttle under its threshold into zero torque, so a negative ROS throttle coasts. Teleop and a planner can drive OVCS1 forward and backward, but neither steer nor brake it.

Options for braking on a negative ROS throttle:
1. Regeneration: a negative torque request to the Leaf inverter. No hydraulics, but limited deceleration and no hold at standstill.
2. The iBooster, as `:radio` brakes: the negative throttle of the commanding source becomes a rod position target. `:ros` reuses the path `:radio` already exercises on the vehicle.
3. Both, blended: the best feel, and the most to verify.

Chosen: 2, the radio's path.

Options for deciding when an actuator acts:
1. A shared list of actuating control levels the components check.
2. The source maps: an actuator acts while `Managers.ControlLevel` names a source for it, so the components know neither the level nor which source drives them.

Chosen: 2. The vehicle's composer already decides, per level, who commands each actuator. The steering column follows `requested_steering_sources`, where OVCS1 maps `manual: nil`. Braking gets its own optional map, `requested_braking_sources`, because the throttle map names the pedal under `:manual`, where the driver brakes.

A stale ROS command expires as before: `RosActuatorCommand.Throttle` zeroes the throttle after 500 ms and steering holds its last angle, so the vehicle coasts as it does under `:radio` today. Braking on link loss is TASK-23 and TASK-24's.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The steering column powers up while a steering source is named and cuts its relay when none is, tested through its loop
- [x] #2 The iBooster brakes on the negative throttle of the braking source `Managers.ControlLevel` names, and zeroes it when none is
- [x] #3 `Managers.ControlLevel` routes and publishes an optional `requested_braking_sources` map, validated like the others
- [x] #4 OVCS1 steers and brakes automatically under `:radio` and `:ros`, not `:manual`, tested from its composer
- [x] #5 vms_core and OVCS1 tests pass, with format, credo and warnings as errors
<!-- AC:END -->
