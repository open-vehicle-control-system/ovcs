---
id: TASK-129
title: Connect GUI simulators to the runner over the simulator link
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
updated_date: '2026-11-17 19:00'
labels:
  - simulator
  - vision
dependencies:
  - TASK-122
  - TASK-172
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The simulator link: TCP, each packet a 32-bit big-endian length, a 16-bit header length, a JSON header and an optional binary body, packets over 16 MiB refused. The runner listens when `OVCS_SIMULATOR_LINK` gives it an address (a port on loopback, or `address:port`), and the GUI simulator connects; without it, the runner keeps its Gazebo world. It is the runner's `SimulatorCore.World` for a GUI simulator that owns the dynamics (TASK-121, decision 1), Godot's client first, in its own repository.

Messages:

| `type` | Direction | Header | Body |
|---|---|---|---|
| `actuation` | runner → simulator, every tick | `time_s`; `drive_torque_nm`, total at the driven axle, split equally between its wheels; `brake_torque_nm`, a magnitude that opposes each wheel's spin and holds it at standstill, split by the vehicle pack's brake bias; `steering_rad`, the bicycle-equivalent front angle, positive left; `driveline_inertia_kg_m2`, the motor's and gearbox's inertia at the driven axle, which changes with the gear | none |
| `state` | simulator → runner, every physics step (60 Hz) | `time_s`; `position_m`, `orientation`, `linear_velocity_m_s`, `angular_velocity_rad_s`, `linear_acceleration_m_s2` (what an IMU reads) in REP-103 frames; per wheel, `angle_rad` (cumulative, signed), `omega_rad_s`, `in_contact` | none |
| `image` | simulator → runner | `camera` (`left`, `right`), `time_s`, `format` | the image |
| `instruments` | runner → simulator | `motor_rpm` | none |

Every message is absolute, so a reconnected simulator recovers from the first one. Each side stamps its own monotonic clock. With no `actuation` for 0.5 s the simulator applies no drive torque and keeps the last brake; while no runner is connected it holds the car with the pack's parking hold. The runner decodes `image` messages; feeding them to the vision unit is TASK-182, and the IMU readings in `state` to the ROS bridge TASK-181. Collisions, wheel lift, rollover and slip come from the simulator's physics; a `contact` event can follow for scenario assertions.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The link protocol is documented and tested, including malformed and oversized packets
- [ ] #2 A disconnected GUI simulator does not stop the runner, and a reconnected one picks up from the next actuation
- [ ] #3 The OVCS Mini drives in Godot from its simulated actuators' efforts, its simulated sensors reporting the wheels' spin from Godot's state
- [ ] #4 A ROS 2 `cmd_vel` drives and steers the OVCS Mini in Godot through the VMS and its simulated actuators
<!-- AC:END -->
