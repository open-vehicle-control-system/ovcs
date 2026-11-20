---
id: TASK-181
title: Feed the simulator's IMU to the ROS bridge
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - simulator
  - ros
dependencies:
  - TASK-129
ordinal: 121000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Against Godot, the ROS bridge runs `OvcsDrivers.Imu.Dummy`: `/imu` stays still and `/odom`'s heading never turns, so Nav2 cannot follow a curve. Against Gazebo, `RosBridge.Imu.Zenoh` consumes the simulated sensor's `imu_raw`. The simulator link's `state` already carries what an IMU reads: `orientation`, `angular_velocity_rad_s` and `linear_acceleration_m_s2`, gravity's reaction included.

Make those readings reach the ROS bridge as `{:imu_sample, %Sample{}}`, so `Publishers.Imu` and `Publishers.Odometry` read them unchanged. Which process turns them into samples (the runner publishing `imu_raw` for the existing Zenoh driver, or an IMU driver of its own) is decided here before code.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Against Godot, `/imu` carries the simulated vehicle's orientation, angular velocity and acceleration, in REP-103 frames, tested
- [ ] #2 Driving a circle in Godot, `/odom`'s heading follows Godot's within a tolerance a check states
- [ ] #3 Against Gazebo, the IMU path is unchanged
<!-- AC:END -->
