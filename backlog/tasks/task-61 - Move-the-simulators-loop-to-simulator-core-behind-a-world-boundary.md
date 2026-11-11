---
id: TASK-61
title: Move the simulator's loop to simulator/core behind a world boundary
status: In Progress
assignee: []
created_date: '2026-11-10 18:41'
updated_date: '2026-11-10 19:26'
labels:
  - simulator
milestone: m-1
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
RosBridge.Simulator.Hardware runs the simulated components against the VMS over CAN, but only from the ROS bridge: its loop is ROS-free except for its two links to Gazebo, the wheel joints read from /joint_states and the drive published on /simulator/drive. Another simulator (CARLA), or none, cannot drive it.

Options:
1. Leave the loop in the ROS bridge and add other simulators there: every vehicle then needs a ROS bridge to be simulated.
2. Move the loop as it is and let it call a ROS module through config: core would still know about ROS topics.
3. Move the loop to simulator/core as SimulatorCore.Hardware and put whatever moves the vehicle behind a SimulatorCore.World behaviour: wheel_turns/2 reads how far the wheels turned from a message the world sends, drive/2 hands the world the vehicle's motion. The ROS bridge keeps only RosBridge.Simulator.World.

Chosen: 3. drive/2 receives the whole SimulatorCore.Vehicle, so a world takes what it needs (Gazebo: speed and yaw rate; CARLA's Ackermann control: speed and steering angle). The :simulated_hardware component keeps its options (:vehicle, :simulated_components, :wheel_joints), so vehicles and guides see no change. A world with no external simulator belongs to the runner without the ROS bridge, a later task. No change in behaviour: the loop's tests with a test world, and the Gazebo drive check before and after, show it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.World declares init/1, wheel_turns/2 and drive/2; SimulatorCore.Hardware runs the loop with a :world option and is tested with a test world in simulator/core
- [x] #2 RosBridge.Simulator.World reads the wheel joints on /joint_states and publishes the drive on /simulator/drive, as the loop did
- [x] #3 The :simulated_hardware component keeps its options; OVCS Mini's configuration does not change
- [x] #4 simulator/core, ros_bridge and OVCS Mini tests pass, with dialyzer and credo
- [x] #5 In Gazebo, the OVCS Mini reaches ros/autonomous and covers the same distance with /odom matching ground truth, before and after
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Vehicle.yaw_rate/1 moved to RosBridge.Simulator.World.twist/1: only Gazebo's AckermannSteering drive uses a yaw rate.

Gazebo drive check (OVCS Mini, 0.5 m/s on /cmd_vel_nav for 8 s, four runs each, same machine and day): main 3.80-3.84 m, this change 3.81-3.83 m; /odom within 0.0 % of ground truth in every run.

The loop tests wait up to 1 s for a 20 ms tick: 600 repetitions passed with one CPU-bound process per core; with two per core, the VM occasionally does not schedule the loop for over a second.
<!-- SECTION:NOTES:END -->
