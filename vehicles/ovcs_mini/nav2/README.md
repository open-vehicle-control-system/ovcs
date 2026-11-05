---
title: OVCS Mini navigation validation
description: Navigation frames, fault handling and the measurements needed to tune the OVCS Mini reference vehicle.
---

## Navigation reference and fault handling

Nav2 plans and controls `base_rear_axle`, at the midpoint of the rear axle on the ground plane. `/odom` describes that frame, whose lateral velocity is zero in the bicycle model. The bridge still publishes `odom → base_link`, and the URDF supplies the fixed `base_link → base_rear_axle` transform. Sensor and chassis frames retain their existing mounts. The footprint translates the same physical envelope into rear-axle coordinates. A navigation goal now locates the rear axle.

The BNO085 uses the game rotation vector, without magnetometer correction. Keep that choice until magnetic interference has been measured on the complete powered vehicle. RotationFusion keeps the VESC as its primary source and the spur pulse sensor as a consistency check. Their agreement cannot detect slip downstream of both sensors.

The velocity consumer requires fresh odometry. Heading and gyro expire independently; a BNO reference reset requires stopping navigation and restarting odometry and rolling costmaps. Rotation-source health additionally controls the VMS's ROS-to-radio fallback and operator rearming. See [bridge behavior](../../../docs/bridges/ros.md) and [rotation-source behavior](../../../docs/vms/drivers.md).

Costmap `expected_update_rate` values are maximum intervals in **seconds**, despite the parameter name. Both marking and clearing inputs have deadlines. Each rear range topic has a separate layer and deadline. These are initial timing budgets to verify under the real compute and network load. A costmap freshness timeout stops control; it is not a measured stopping-distance guarantee. In Nav2 1.5.1, a range layer that becomes non-current needs a costmap reset before navigation resumes, even after readings return.

## Implemented configuration corrections

| Area | Configuration |
|---|---|
| Ackermann origin | Rear-axle robot frame, odometry pose/twist and translated footprint agree. |
| Lyrical path handler | `prune_distance` belongs to `PathHandler`; path-transform tolerance comes from the local costmap. |
| Reverse paths | `PathAngleCritic.mode: 2` and `PathAlignCritic.use_path_orientations: true` respect feasible path orientations. |
| Velocity smoothing | `scale_velocities: true` scales velocity changes together within acceleration constraints; measure resulting curvature during transients. |
| Recovery | Both backup trees and drive-behavior minimum speeds use the VMS floor. No Spin action or Spin server is configured. |
| Sensor freshness | Stereo marking/clearing, lidar and each rear ultrasonic have deadlines. |
| STVL | `mark_threshold` counts occupied vertical voxels in a projected column, not repeated clouds. |
| Denoising | Local and global cluster cutoffs account for their different cell areas. Validate small obstacles before driving. |
| Runtime cost | MPPI trajectory visualization defaults off; enable it temporarily for tuning. |

## Vehicle validation sequence

1. With the wheels lifted, verify startup calibration, heading/gyro signs, steering direction and each input rate. Stop each source independently, including only one BNO report kind and only one rear ultrasonic. Confirm commands become zero, rotation health forces radio when required, and recovery requires the documented rearming or reset.
2. On a clear measured course, record straight travel and constant-radius turns in both directions. Compare tape measurements with `/odom`, speed feedback and commanded speed. Repeat forward and reverse with the normal battery and payload.
3. Measure start/stop transients, minimum stable speed, acceleration, braking and steering delay. Set command and sensing margins from these measurements before increasing speed.
4. Place low obstacles, chair legs and narrow objects at the sides and front, including on the glossy floor. Inspect both costmaps and repeat while turning and reversing. A path that appears clear is insufficient if either sensor cannot see the obstacle.
5. Run forward curves, reverse curves, a direction-changing cusp, a blocked approach, a narrow passage and a goal near the vehicle. Record goal success, path length, reversals, lateral error, steering reversals, controller cycle time and minimum clearance. Compare one tuning change at a time.

Record `/odom`, `/imu`, `/scan`, `/stereo/points`, both `/ultrasound/rear_*` topics, `/tf`, `/tf_static`, `/cmd_vel_nav_raw`, `/cmd_vel_nav`, the planned path and VMS rotation/health metrics. Capture sensor dropout logs as well as successful runs. Preserve the parameter file and geometry with each recording.

## Remaining measurement and design work

These items are not calibrated by the configuration corrections. Keep the existing limits until the stated evidence is available.

| Finding | Next action and acceptance evidence |
|---|---|
| Minimum-speed model mismatch | Measure stable forward/reverse speed under load. MPPI still samples below the VMS's nonzero speed floor; the deadband critic only penalizes that band. Choose a validated lower actuator floor or a matching controller model, then verify starts, stops and cusp tracking. |
| Wheel-distance scale | Measure loaded rolling circumference over several turns. Reconcile the model's 52.2 mm radius with catalogue tyre dimensions, and verify gearing using an independent distance measurement. |
| Steering and turn radius | Measure left/right steering at the wheels, servo delay and minimum rear-axle turn radius. Update geometry and both planner/controller radius limits together. |
| Actual footprint | Measure body, wheels and mounted equipment through steering travel. Check both costmap footprints against the swept envelope. |
| IMU mount | Measure position and roll/pitch/yaw. Update the URDF; odometry reads its rotation. Prefer a rigid mount away from vibration and motor wiring, and verify axes after installation. Translation alone does not repair heading drift. |
| BNO calibration and report rate | Check stationary gyro bias and accuracy status before motion. Measure three-stream rate, queueing and latency at 50 Hz; trial 100 Hz only if I²C and bridge load allow it. |
| Acquisition-time alignment | Capture the BNO interrupt timestamp and wheel acquisition time, measure CAN/network delay, then interpolate heading at wheel-sample time. Current IMU time is poll-anchored; wheel frames remain arrival-stamped. |
| Velocity estimator lag | Compare the 200 ms tachometer window with shorter/adaptive or count-based estimators using logged counts. Evaluate quantization and stop detection; retain cumulative-count distance integration. |
| Low-speed rotation cross-check | Characterize pulse period and stopping decay. The 450 motor-RPM comparison threshold does not cover the whole 0.15 m/s operating band. Adjust windows/thresholds only against measured false alarms and missed faults. |
| Acceleration and braking | Measure stopping distance including sensing, control, smoothing and actuator delay, at several speeds and battery states. Reconcile MPPI, smoother and VMS limits. |
| Low front obstacles | Stereo ignores points below 0.12 m and the lidar plane is higher. Test low objects and floor reflections before changing height filters, voxel threshold, denoising or sensor placement. |
| Reverse preference | Evaluate cusp convergence with the orientation-aware critics. Tune `PreferForwardCritic` and Smac reverse penalty against reversals and completion time. |
| Analytic expansion | Benchmark the existing 1.0 m cap against 3.2–4.0 m, around four to five times the planner radius. Compare planning time, tight goals and unintended long reverse shortcuts before adopting a larger cap. |
| Controller load | Benchmark the real compute node with normal vision and network traffic before increasing frequency, horizon or sample count. |
| Localization | Add and validate lidar SLAM/localization supplying `map → odom`; use `map` for the global costmap and keep the local costmap in `odom`. The current configuration remains dead reckoning. |
| Optional 2D EKF | First measure covariances and provide independent wheel and IMU inputs. Do not fuse the current IMU-derived odometry heading as an independent observation of the same `/imu` heading. |
| Downstream feedback | Add a direction-aware wheel/output encoder if clutch slip or true low-speed/reverse feedback must be observed. Both current rotation sensors are upstream of the slipper clutch. |
| Collision Monitor | Add it after the velocity smoother as the sole publisher of `/cmd_vel_nav`. Choose stop polygons and source timeouts from measured stopping distances and coverage, then test missing data and all approach directions. It is not enabled by this configuration. |

## Local checks

Run the vehicle's geometry and navigation consistency tests from `vehicles/ovcs_mini`:

```sh
mise exec -- mix test --no-start
```

Regenerate the committed URDF after geometry edits, from the repository root with the ROS environment sourced:

```sh
mise run urdf
```

With the local `ovcs/nav2:lyrical` image built, run the isolated Nav2 runtime check:

```sh
vehicles/ovcs_mini/nav2/test_runtime.sh
```

It starts all five servers, verifies a Smac plan starts at the rear axle, and checks that independently stopping lidar, stereo or either ultrasonic stops the final command while other sensors continue. Docker has no external network and publishes only synthetic sensor data; the test uses Fast DDS inside the container. It does not measure the vehicle's Zenoh/network latency, physical stopping distance or path tracking.

The BNO driver suite covers packet decoding, duplicate sequences, report loss, reset recovery and bounded polling. The ROS bridge suite covers mounting rotation, capture timestamps, IMU freshness, heading-reference resets, arc integration and command gating. These checks establish software behavior; the measured-course and obstacle tests establish vehicle performance.
