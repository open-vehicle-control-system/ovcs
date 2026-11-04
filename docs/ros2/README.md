---
title: ROS 2
description: The Zenoh fabric, who publishes which topic, simulator time, the command paths, the VMS driving Gazebo, Nav2 and the vision unit.
---

This page describes what runs when OVCS talks to ROS 2, who owns time, and which command path is real. [Simulation](../../compose/local/simulation/README.md) tells you how to run the simulator; read it first.

> [!NOTE]
> The ROS bridge library, the Zenoh client, the message codecs, the VMS command components and the container images are framework. The **vehicle** decides which topics a bridge publishes and consumes, which drivers it uses and where the router lives, in its `ros_bridge_config/1` or `/2` (see [Vehicle package](../vehicle_package.md)).
>
> Everything here was built and measured on the **OVCS Mini reference vehicle**. It runs the ROS bridge in its `ros` bridge firmware, stereo depth and detection in its vision unit, and a compute node. Treat its wiring as a worked example for your own.

## The fabric: one Zenoh router, everything a client

Everything ROS-shaped speaks **Zenoh**, not DDS. ROS 2 nodes use `rmw_zenoh_cpp`. The Elixir bridge speaks the `rmw_zenoh` wire format natively through `zenohex` and links nothing from ROS. Every participant is a *client* of one router (`zenohd`). There is no multicast discovery to configure, and a simulated vehicle appears on the same fabric as a real one.

The vehicle is the router, so the fabric survives the laptop leaving. For a simulator session with no vehicle on the LAN, `compose/local/base.yml` carries a copy of `zenohd` behind the `standalone` profile.

Three consequences of the wire format:

- **A topic is a key expression.** `rmw_zenoh` maps `/cmd_vel` to `0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_<hash>`. The bridge subscribes with a `/**` wildcard after the topic and matches by prefix. It can therefore subscribe by *topic* without knowing the type hash. It is also why subscribing with the wrong message module fails silently (see [Two things that fail silently](./commands.md#two-things-that-fail-silently)).
- **Payloads are CDR** with a four-byte encapsulation header (`00 01 00 00`) and a 33-byte attachment carrying sequence number, source timestamp and publisher GID. `rmw_zenoh` subscribers drop samples without a well-formed attachment.
- **Discovery is a liveliness token**, not data. A publisher is invisible to `ros2 topic list` and Foxglove until it declares one on `@ros2_lv/...`, even while its samples flow.

[`bridges/ros_bridge/README.md`](../../bridges/ros_bridge/README.md) has the format in full, including how to add a message type.

## Who runs what

Everything containerised lives under `compose/`, split by one question: is it pushed to the vehicle, or does it never leave a workstation?

| Service | Stack | Why there |
|---|---|---|
| `zenohd` | `compose/compute` | the fabric outlives the operator's laptop |
| `foxglove_bridge` | `compose/compute` | Foxglove Studio attaches over the LAN on port 8765 |
| `nav2` | `compose/compute` | the planner survives the base station leaving, like the router |
| `wifi_firmware`, `wifi_ap_radio`, `bridge_no_nat`, `ntp` | `compose/compute` | host plumbing for the compute node's network; not ROS |
| `ros2` (tooling shell), `joy`, `calibrator` (profile `calibration`) | `compose/local/base.yml` | the operator's side: CLI, game controller, `cameracalibrator`'s stereo calibration GUI |
| `zenohd`, `foxglove_bridge` (profile `standalone`), `nav2` (profile `nav2`) | `compose/local/base.yml` | stand-ins for the vehicle's own, when none is on the LAN |
| `gazebo`, `gazebo-gui`, `nav2` | `compose/local/simulation.yml` | Gazebo, its viewer, and Nav2 on its clock |

`compose/compute/` is pushed to balena as one unit. `./ovcs compute push` stages your vehicle's Nav2 parameters into it. `compose/local/` is never pushed.

The vehicle's images are built only from `compose/compute/images/`, and the local stacks build the same Dockerfiles, so a workstation runs what the car runs.

A stand-in must not run while a vehicle is on the LAN: two routers are two fabrics.

The profile table is in [`compose/README.md`](../../compose/README.md). The compute node itself is described in [ROS compute node](./compute_node.md).

The `calibrator` is one of two ways to calibrate the vision unit's stereo cameras. The unit's dashboard calibrates them on its own, with the same OpenCV steps, and needs neither ROS 2 nor an X display; both commit through the same code on the unit. [Calibrate the cameras](../vision/calibration.md) covers the two.

## What the simulator starts

[Simulation](../../compose/local/simulation/README.md#what-the-simulator-starts) has the launch order, the bridged topics and the details that look like bugs (server-only Gazebo, `-r`, `GZ_IP`, the step rate).

## Topics: who publishes what

The boundary between Gazebo's transport and ROS is exactly the list in `gazebo.launch.py`.

| Topic | Type | Publisher | Consumer |
|---|---|---|---|
| `/clock` | `rosgraph_msgs/Clock` | Gazebo | every node, `RosBridge.Clock` |
| `/odom`, `/tf` (`odom → base_link`) | `nav_msgs/Odometry`, `tf2_msgs/TFMessage` | `RosBridge.Publishers.Odometry` | Nav2, Foxglove |
| `/tf_static` | `tf2_msgs/TFMessage` | `robot_state_publisher` | Nav2, Foxglove |
| `/joint_states` | `sensor_msgs/JointState` | Gazebo; on the vehicle, `RosBridge.Publishers.AckermannJointStates` | `RosBridge.Simulator.World` (the wheel speed), `robot_state_publisher` |
| `/imu_raw` | `sensor_msgs/Imu` | the model's IMU sensor | `RosBridge.Imu.Zenoh`, republished on `/imu` by `Publishers.Imu` |
| a ray sensor's `*_raw` topic | `sensor_msgs/LaserScan` | a `gpu_lidar` in the model | `RosBridge.Lidar.Zenoh` for a lidar, `RosBridge.Rangefinder.Zenoh` for a fan standing in for one rangefinder beam; republished as on the vehicle |
| `/stereo/{left,right}/image_raw/compressed` | `sensor_msgs/CompressedImage` | `image_bridge` | `VisionCore.Ros2.Camera` |
| `/stereo/{left,right}/camera_info` | `sensor_msgs/CameraInfo` | Gazebo **and** the vision unit (from its calibration YAML) | Foxglove, the calibrator |
| `/cmd_vel_nav_raw` | `geometry_msgs/TwistStamped` | Nav2 `controller_server`, `behavior_server` | Nav2 `velocity_smoother` |
| `/cmd_vel_nav` | `geometry_msgs/TwistStamped` | Nav2 `velocity_smoother` | `RosBridge.Consumers.Velocity` |
| `/joy/<profile>` | `sensor_msgs/Joy` | the operator's `joy` service | `RosBridge.Consumers.Joy` |
| `/simulator/drive` | `geometry_msgs/Twist` | `RosBridge.Simulator.World` ([simulated hardware](./commands.md#the-vms-drives-the-simulator)) | `AckermannSteering` |
| `/simulator/odom` | `nav_msgs/Odometry` | the model's `OdometryPublisher`: [ground truth](./commands.md#ground-truth) | you, to compare with `/odom` |
| `/stereo/...` disparity, depth, points, detections | `stereo_msgs`, `sensor_msgs`, `vision_msgs` | the vision unit | Nav2, Foxglove |
| `/stereo/{left,right}/image_rect/compressed` | `sensor_msgs/CompressedImage` | the vision unit, with `publish_rectified_image: true`; their intrinsics are `/stereo/depth/camera_info` | displays that draw over the image, Foxglove |
| `/octomap/point_cloud_centers` | `sensor_msgs/PointCloud2` | the Nav2 image's `octomap_server`, from `/stereo/points`, for a vehicle with `nav2/octomap.yaml` | displays, Foxglove |
| `<cloud>/draco` | `point_cloud_interfaces/CompressedPointCloud2` | the Nav2 image's `point_cloud_transport`, for `/stereo/points` and the OctoMap map, for a vehicle with `nav2/draco.yaml` | displays over a wireless link |
| `/vehicle/*` | `std_msgs/String`, `Bool`, `Float64` | `RosBridge.Publishers.VehicleStatus`, from the VMS's `0x1A0`, `0x600` and `0x60C` | Foxglove: the control level, ROS commander, gear, ready to drive, VMS status and requested throttle and steering |
| `/vehicle/predicted_path`, `/vehicle/predicted_pose` | `nav_msgs/Path`, `geometry_msgs/PoseStamped` | `RosBridge.Publishers.PathPrediction`, from the VMS's `0x60B` and `0x600` | displays drawing where the vehicle heads |
| `/proximity/nearest`, `/proximity/labels` | `sensor_msgs/Range`, `visualization_msgs/MarkerArray` | `RosBridge.Publishers.Proximity`, from `/scan` | displays, Foxglove |
| `/ovcs_heartbeat` | `std_msgs/String` | every `RosBridge` that lists `:heartbeat` | you, to see the BEAM is alive |

**Two transform buffers.** `/tf` is time-indexed: `tf2` stores each sample against its stamp and interpolates. `/tf_static` is timeless. It carries the URDF's fixed joints, the sensor mounts among them; a point cloud stamped after the newest `/tf` sample could not be transformed, and Nav2 would drop it.

`robot_state_publisher` publishes them. In the simulator, the launch runs it; on the vehicle, the Nav2 image does. The nav2 service in the simulator's stack therefore starts with `robot_state_publisher:=false`. The bridges stamp their messages with the URDF's frame names (`lidar_link`, `stereo_left_optical`, ...) in both.

The wheels' joints move, so their transforms are on `/tf`, from `/joint_states`. In the simulator, Gazebo publishes `/joint_states`. On the vehicle, the ROS bridge's `:ackermann_joint_states` does, from the VMS's commanded steering and the wheels' distance.

**Meshes.** Foxglove fetches a model's meshes through `foxglove_bridge` only when they are `package://` URIs. The framework therefore expands your model with its meshes in the `ovcs_description` package, through a `mesh_uri` xacro argument (`package://ovcs_description/meshes`).

The shared ROS image registers that package at `/opt/ovcs/description`. On the vehicle, `ovcs compute stage` bakes your vehicle's `description/` there; locally, `foxglove_bridge` mounts it. Gazebo finds it on `GZ_SIM_RESOURCE_PATH`.

To draw the model, enable `/robot_description` in a 3D panel and set the panel's mesh up axis to Z-up (`scene.meshUpAxis: z_up`). ROS meshes are Z-up; Foxglove assumes Y-up and turns them 90°.

## Time

Time is the most likely source of problems, because every failure it causes looks like something else.

### Gazebo owns the clock

`use_sim_time: true` means "stamp with `/clock`, not the wall". Gazebo starts its clock at zero and advances it with physics, so a wall-clock stamp (1.79e9 s) sits decades away from everything else. Any consumer comparing stamps across topics drops the message, usually with a `tf2` extrapolation error that reads as a transform problem.

ROS nodes get this from the parameter. The Elixir bridge is not a ROS node, and its drivers stamp frames with Erlang monotonic time, so something has to convert.

| Part | Clock | Why |
|---|---|---|
| Gazebo | simulated | It is the clock: `/clock` is published once per physics step. |
| Nav2, `robot_state_publisher` | simulated (`use_sim_time`) | Gazebo stamps its images, joint states and odometry in simulated time, and the transform tree has to agree. |
| The ROS bridge's publishers | wall, stamped in simulated time | Drivers keep local time; `RosBridge.Timing` converts each stamp, below. |
| The VMS | wall | Unchanged from the vehicle: it measures rates and timeouts in real seconds. |
| The simulated hardware | wall | It answers the VMS, so it measures as the VMS does, and takes distances from Gazebo's wheels ([The VMS drives the simulator](./commands.md#the-vms-drives-the-simulator)). |

### The bridge tracks an offset, not the clock

Each `/clock` sample gives a simulator time and, read alongside it, a local monotonic time. `RosBridge.Clock` stores the difference in `:atomics` for lock-free reads. `RosBridge.Timing.stamp_from_monotonic/1` projects any monotonic capture time through it:

```text
/clock sample t_sim ─► RosBridge.Clock: offset = t_sim − t_mono ─► :atomics
driver frame (capture_ns, Erlang monotonic) ─► Timing: capture_ns + offset ─► builtin_interfaces/Time
```

Drivers never see simulator time. Lidar and rangefinder samples carry system time, and the other publishers stamp the Erlang-monotonic time they publish at. `Timing` is the one place either is converted.

The vision unit does the same with `VisionCore.Timing`. Its `VisionCore.Ros2.Camera` converts the other way, through `VisionCore.Timing.monotonic_from_export_time/1`. A simulated frame's `capture_ns` is Gazebo's render stamp, so both sides of a stereo pair carry the same time and pair exactly. Stamped on arrival instead, they arrive tens of milliseconds apart. That is enough to pair a frame with its neighbour's, which reads as phantom depth once the car moves.

Without a `/clock` the offset is `nil` and `Timing` stamps wall clock, so the vehicle path is untouched.

### Two monotonic clocks, not one

Erlang's monotonic time is not the kernel's `CLOCK_MONOTONIC`: the VM picks its own zero, about 5.8e17 ns away. libcamera's `SensorTimestamp` is kernel-monotonic. A timestamp from one clock, projected with the other's offset, lands decades off. `builtin_interfaces/Time.sec` is an `int32`, so it wraps negative. `VisionCore.Timing.monotonic_from_kernel/1` converts once, at the camera driver boundary.

### Why `Clock.init/1` blocks

`RosBridge.Clock` waits for the first `/clock` sample **before returning**, holding up the rest of the supervision tree. `tf2` prunes its buffer relative to its **newest** entry. One wall-clock `/tf_static` message published before the offset is known discards every simulator-time entry that follows, and never ages out. Every point cloud afterwards is rejected with

```text
the timestamp on the message is earlier than all the data in the transform cache
```

and the costmaps ignore stereo for the whole run. Measured, the static-transform publisher wins that race by zero milliseconds. Blocking in `init/1`, with `:simulator_clock` listed before the transforms, removes the race.

### Giving up is permanent

If no `/clock` arrives within 60 s (`:acquire_timeout_ms`), the bridge unsubscribes and stays on wall clock for the run. Switching later would be worse: wall-clock stamps would already be in `tf2`'s buffer. The deadline is generous because `docker compose up -d` returns long before Gazebo has loaded a world and spawned the robot.

## Commands

Joystick positions and planner velocities reach the VMS on two CAN frames, `0x2B0` and `0x2B1`. [Command paths](./commands.md) covers both, the loop the VMS closes with the simulator, and the switches that decide who commands.

## Nav2, as configured here

The stack is Nav2 1.5.1: a lifecycle manager and four servers (`controller_server`, `planner_server`, `behavior_server`, `bt_navigator`) plus `velocity_smoother`. It does not use `nav2_bringup`, which is absent from the Lyrical archive and would pull in map_server and AMCL.

One configuration serves three deployments. The parameter file and behaviour trees are the vehicle's, in `vehicles/<vehicle>/nav2/`. The image and its launch file are the framework's, in `compose/compute/images/nav2/`; the image is tagged `ovcs/nav2:lyrical` wherever it is built.

`./ovcs compute stage` bakes the vehicle's parameters and its expanded URDF into the onboard image; the local stacks mount them.

| Where | Compose | Clock |
|---|---|---|
| The vehicle's compute node | `compose/compute/docker-compose.yml`, always on | wall |
| A dev machine, against a host VMS and bridge | `compose/local/base.yml --profile nav2` | wall |
| Against the simulator | `compose/local/simulation.yml --profile nav2` | `use_sim_time:=true` |

The file holds the vehicle's values (`use_sim_time: false`). The simulator overrides the clock with a launch argument rather than keeping a copy that would drift.

```text
NavigateToPose goal ─► bt_navigator ─► planner_server (Smac Hybrid-A*) ─► path
                                   └─► controller_server (MPPI) ◄─ /odom, /tf, costmaps (the vehicle's obstacle sources)
controller_server, behavior_server ─/cmd_vel_nav_raw─► velocity_smoother ─/cmd_vel_nav @ 20 Hz─►
```

What is deliberately unusual:

- **No map, no AMCL.** Every frame is `odom` and both costmaps roll with the vehicle. That is enough to prove the velocity path drives an Ackermann vehicle without the SLAM question. There is no fake static `map → odom`, which looks like localisation and is not.
- **`AckermannConstraints`.** MPPI's `motion_model` names a plugin *instance*; the class, `mppi::AckermannMotionModel`, comes from `<instance>.plugin`. It clamps yaw rate to `|vx| / min_turning_r` inside the sampler, so infeasible arcs are never considered. `min_turning_r` is `0.324 / tan(0.52) = 0.566 m`, rounded up to 0.6.
- **`TwistStamped` on `/cmd_vel_nav`.** `nav2_util::TwistPublisher` defaults `enable_stamped_cmd_vel` to true. Its header comment says otherwise; the behaviour follows the code.
- **The rest is the vehicle's.** Obstacle sources, speed limits, reverse and recovery distances follow from a vehicle's sensors and drivetrain. The OVCS Mini reference vehicle's are in [its README](../../vehicles/ovcs_mini/README.md#navigation).
- **No `Spin` in either behaviour tree.** A car produces no motion from a spin, so it ran its full duration and used up a recovery slot. The spin *server* stays loaded because `bt_navigator` resolves every action at activation.
- **Smac Hybrid-A\*, built from source.** `nav2_smac_planner` is released for Lyrical but absent from its archive. The Nav2 image therefore builds it from that release's source, at the version of the Nav2 packages it installs. It plans arcs the vehicle can drive. A grid planner such as NavFn plans corners and sideways steps, and MPPI moves forward and back against them. The Smac planner's `configure` must finish inside rmw_zenoh's 10 s service timeout, or the lifecycle manager gives up. The Reeds-Shepp `lookup_table_size` sets that time.
- **`default_server_timeout` is 1 s.** A behaviour-tree node waits that long for a server to accept its request. The default 20 ms is missed over Zenoh while the planner is searching, and a missed acknowledgment fails the whole goal.
- **`yaw_goal_tolerance` is 3.15.** A car cannot rotate in place to a final heading.

### Arriving proves almost nothing

Gazebo's `AckermannSteering` silently ignores commands it cannot execute. With `mppi::DiffDriveMotionModel` substituted in, the vehicle reached the tight goal *better* than the correct configuration (0.30 m against 0.53 m). It did so while commanding **3.68×** the kinematic yaw-rate limit. Judge a configuration by what it *commands*, not by whether it arrives.

## The vision unit against the simulator

The vision unit runs unchanged against Gazebo. Only the camera driver differs: `VisionCore.Ros2.Camera` in place of `VisionCore.Camera.LibCamera`. [Running the vision unit against it](../../compose/local/simulation/README.md#running-the-vision-unit-against-it) covers the wiring, why the images are compressed, and the simulator's own calibration.

## Per-vehicle bridge configuration

Every feature of `RosBridge` is a component your vehicle opts into through `%RosBridge.Config{}`. [Configure it in your vehicle](../bridges/ros.md#configure-it-in-your-vehicle) has the arms, the OVCS Mini's configuration, and the node names two bridges on one fabric need.

## Version pins

These versions move together. The `pins` job in `.github/workflows/ros2.yml` fails when the router image and the Python client disagree. It does not read `bridges/ros_bridge/mix.exs`, so check the `zenohex` pin by hand.

| What | Value | Where |
|---|---|---|
| zenoh in the ROS nodes | `rmw_zenoh_cpp` 0.10.5: zenoh 1.8.0 plus fixes, before 1.9.0's routing rewrite | the ROS snapshot in `compose/compute/images/*/Dockerfile` |
| zenoh router image | `eclipse/zenoh:1.8.0` | `compose/compute/docker-compose.yml`, `compose/local/base.yml` |
| zenoh Python client | `eclipse-zenoh==1.8.0` | `compose/compute/images/ros2/Dockerfile` |
| zenoh in the Elixir bridge | `zenohex ~> 0.8.0` (zenoh 1.8.0) | `bridges/ros_bridge/mix.exs` |
| ROS 2 distribution | `ros:lyrical-ros-base` | `compose/compute/images/{ros2,nav2}/`, `compose/local/images/gazebo/` |
| Gazebo | Jetty, via `ros-lyrical-ros-gz` | `compose/local/images/gazebo/Dockerfile` |

## Verifying end to end

With `./ovcs run <vehicle>` running and the `compose/local/base.yml` stack up, run:

```sh
cd compose/local && docker compose -f base.yml exec ros2 bash -lc '
  source /opt/ros/*/setup.bash
  ros2 topic list
  ros2 topic info -v /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

Or open Foxglove Studio against `ws://<docker-host>:8765` and subscribe to `/ovcs_heartbeat`.

`compose/local/foxglove/ovcs_stereo_tuning.json` is for tuning the stereo cameras. A vehicle's own layouts live in its `foxglove/` directory. The OVCS Mini reference vehicle has `ovcs_nav2.json` for the planner and `ovcs_stereo.json` for the stereo pipeline.

> [!TIP]
> If `ros2 topic echo` fails with `ResponseError: unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'` (a `ros2cli` daemon bug on Python 3.14), pass `--no-daemon`.

## Reading map

| To understand | Read | Then |
|---|---|---|
| how to run any of this | [Simulation](../../compose/local/simulation/README.md) | `compose/local/simulation.yml` |
| the launch order and bridged topics | `compose/local/simulation/launch/gazebo.launch.py` (its docstrings are the design notes) | `compose/compute/images/nav2/launch/nav2.launch.py` |
| the rmw_zenoh wire format | [`libraries/ros2_zenoh/README.md`](../../libraries/ros2_zenoh/README.md) | `libraries/ros2_zenoh/lib/ros2_zenoh/rmw_zenoh.ex`, `libraries/ros2_zenoh/lib/ros2_zenoh/client.ex` |
| time | `bridges/ros_bridge/lib/ros_bridge/clock.ex` | `timing.ex`, `publishers/static_transform.ex` |
| what a vehicle's ROS bridge runs | `vehicles/ovcs_mini/lib/ovcs_mini.ex` (`ros_bridge_config/1`) | `bridges/ros_bridge/lib/ros_bridge/components.ex` |
| the actuator command path | `bridges/ros_bridge/lib/ros_bridge/consumers/joy.ex` | `libraries/ovcs_can/priv/can/components/ovcs/0x2B0_ros_actuator_command.yml`, `vms/core/lib/vms_core/components/ovcs/ros_actuator_command/` |
| the velocity command path | `bridges/ros_bridge/lib/ros_bridge/consumers/velocity.ex` | `0x2B1_ros_velocity_command.yml`, `vms/core/lib/vms_core/components/ovcs/ros_velocity_command.ex` |
| odometry on the vehicle | `bridges/ros_bridge/lib/ros_bridge/publishers/odometry.ex` | `0x60B_vehicle_motion.yml`, `vms/core/lib/vms_core/components/ovcs/vehicle_motion.ex` |
| the VMS in the simulator's loop | `simulator/core/lib/simulator_core/hardware.ex` | `bridges/ros_bridge/lib/ros_bridge/simulator/world.ex` (Gazebo), `simulator/core/lib/simulator_core/vehicle.ex`, `simulator/core/lib/simulator_core/simulated_components/`, `ros_bridge_simulation_config/0` in `vehicles/ovcs_mini/lib/ovcs_mini.ex` |
| who commands the vehicle | [How the VMS works](../vms/how_it_works.md#control-levels) | `vms/core/lib/vms_core/managers/control_level.ex` |
| the vehicle's state on ROS | `bridges/ros_bridge/lib/ros_bridge/publishers/vehicle_status.ex` | `0x60C_control_status.yml`, `vms/core/lib/vms_core/components/ovcs/control_status.ex` |
| Nav2's configuration | `vehicles/ovcs_mini/nav2/nav2.yaml`, the OVCS Mini reference vehicle's (heavily commented) | `nav2_ackermann_bt.xml` beside it |
| stereo depth and detection | [Vision unit](../vision/README.md) | `vision/core/lib/vision_core/ros2/camera.ex`, `stereo/supervisor.ex` |
| the vehicle's ROS computer | [ROS compute node](./compute_node.md) | `compose/compute/`, [`compose/README.md`](../../compose/README.md) |
| the model's geometry | `vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro`, the OVCS Mini reference vehicle's | `gazebo_ackermann.xacro`, `simulation.yaml`; `ovcs_mini.urdf`, which `mise run urdf` expands from it and `OvcsMini.geometry/0` reads |
