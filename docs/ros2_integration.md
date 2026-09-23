---
title: ROS 2 and the simulator
description: The Zenoh fabric, who publishes which topic, simulator time, the three command paths, Nav2, perception, and what each verifier proves.
---

A map, not a manual: what runs when OVCS talks to ROS 2, who owns time, which command path is real, and what each verifier proves. [Simulation](../compose/local/simulation/README.md) tells you how to run the simulator; read this first.

> [!NOTE]
> The ROS bridge library, the Zenoh client, the message codecs, the VMS command components and the container images are framework. Which topics a bridge publishes and consumes, which drivers it uses and where the router lives are decided by the **application**, in its `ros_bridge_config/2`. Everything here was built and measured on the **OVCS Mini reference application**, the one that runs a ROS bridge, a perception bridge and a compute node: treat its wiring as a worked example for your own.

> [!WARNING]
> In simulation, the gamepad and Nav2 drive Gazebo's physics **directly**. The VMS and the CAN bus are **not in that loop**; only the Elixir bridge's perception (and, on the host bridge, the IMU) runs against the simulator. A CAN frame is not what moves the simulated car. [Commands](#commands-three-paths-and-a-gap) shows both loops.

## The fabric: one Zenoh router, everything a client

Everything ROS-shaped speaks **Zenoh**, not DDS. ROS 2 nodes use `rmw_zenoh_cpp`; the Elixir bridge speaks the `rmw_zenoh` wire format natively through `zenohex` and links nothing from ROS. Every participant is a *client* of one router (`zenohd`): no multicast discovery to configure, and a simulated vehicle appears on the same fabric as a real one.

The vehicle is the router, so the fabric survives the laptop leaving. With no vehicle on the LAN, `compose/local/base.yml` carries a copy of `zenohd` behind the `standalone` profile; every simulator session and every `verify-*` task uses it.

Three consequences of the wire format:

- **A topic is a key expression.** `rmw_zenoh` maps `/cmd_vel` to `0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_<hash>`. The bridge subscribes with a `/**` wildcard after the topic and matches by prefix, so it can subscribe by *topic* without knowing the type hash. It is also why subscribing with the wrong message module fails silently ([below](#two-things-that-fail-silently)).
- **Payloads are CDR** with a four-byte encapsulation header (`00 01 00 00`) and a 33-byte attachment carrying sequence number, source timestamp and publisher GID. `rmw_zenoh` subscribers drop samples without a well-formed attachment.
- **Discovery is a liveliness token**, not data. A publisher is invisible to `ros2 topic list` and Foxglove until it declares one on `@ros2_lv/...`, even while its samples flow.

[`bridges/ros_bridge/README.md`](../bridges/ros_bridge/README.md) has the format in full, including how to add a message type.

## Who runs what

Everything containerised lives under `compose/`, split by one question: is it pushed to the vehicle, or does it never leave a workstation?

| Service | Stack | Why there |
|---|---|---|
| `zenohd` | `compose/compute` | the fabric outlives the operator's laptop |
| `foxglove_bridge` | `compose/compute` | Foxglove Studio attaches over the LAN on port 8765 |
| `nav2` | `compose/compute` | the planner survives the base station leaving, like the router |
| `wifi_firmware`, `wifi_ap_fix`, `bridge_nat_fix` | `compose/compute` | host plumbing for the compute node's network; not ROS |
| `ros2` (tooling shell), `joy`, `calibrator` | `compose/local/base.yml` | the operator's side: CLI, game controller, stereo calibration GUI |
| `zenohd`, `foxglove_bridge` (profile `standalone`), `nav2` (profile `nav2`) | `compose/local/base.yml` | stand-ins for the vehicle's own, when none is on the LAN |
| `sim`, `teleop`, `gz-gui`, `nav2` | `compose/local/simulation.yml` | Gazebo and its operator-side extras |

`compose/compute/` is pushed to balena as one unit; `compose/local/` never is. The vehicle's images are built only from `compose/compute/images/`, and the local stacks build the same Dockerfiles, so a workstation runs what the car runs. A stand-in must not run while a vehicle is on the LAN: two routers are two fabrics. The profile table is in [`compose/README.md`](../compose/README.md); the compute node itself is [ROS compute node](./ros_compute_node.md).

## What the simulator starts

`compose/local/simulation/launch/sim.launch.py` brings up one vehicle in one world, in this order:

1. `robot_state_publisher` expands the xacro and publishes `/robot_description`.
2. `gz sim -s -r` loads the world, server-only, running.
3. Two `parameter_bridge` nodes bridge `/clock`, `/odom`, `/tf`, `/joint_states`, `/imu_raw`, both `camera_info` topics and the two command topics.
4. One `image_bridge` per camera (compressed).
5. `ros_gz_sim create` spawns the model from `/robot_description`. The model exists only now, so it comes last.
6. With `teleop:=true`, `joy_linux` and `teleop_twist_joy`.

Details that read like bugs until you know them:

- **`-s` is server-only.** The GUI is a separate service (`--profile gui`), because in a headless container Qt calls `qFatal` and takes the physics down with it.
- **`-r` runs the world.** Without it the simulation loads paused, which looks exactly like a broken drive plugin.
- **Two `parameter_bridge` nodes**, because Nav2 publishes `TwistStamped` and teleop publishes `Twist`: one topic cannot carry both types.
- **Cameras go through `image_bridge`**, for bandwidth ([Perception](#perception-against-the-simulator)).
- **`use_sim_time: true`** on every node ([Time](#time)).

The model lives with its vehicle, in `vehicles/ovcs_mini/description/`, and is mounted into the container rather than baked in. Another application's model is another `description/` directory plus one mount line in `compose/local/simulation.yml`.

## Topics: who publishes what

The boundary between Gazebo's transport and ROS is exactly the list in `sim.launch.py`.

| Topic | Type | Publisher | Consumer |
|---|---|---|---|
| `/clock` | `rosgraph_msgs/Clock` | Gazebo | every node, `RosBridge.Clock` |
| `/odom`, `/tf` (`odom → base_link`) | `nav_msgs/Odometry`, `tf2_msgs/TFMessage` | `AckermannSteering` (sim) or `RosBridge.Publishers.Odometry` (vehicle) | Nav2, Foxglove |
| `/tf_static` | `tf2_msgs/TFMessage` | `robot_state_publisher` **and** `RosBridge.Publishers.StaticTransform` | Nav2, Foxglove |
| `/joint_states` | `sensor_msgs/JointState` | Gazebo | `drive_test.py` |
| `/imu_raw` | `sensor_msgs/Imu` | the model's IMU sensor | `RosBridge.Imu.Zenoh`, republished on `/imu` by `Publishers.Imu` |
| `/stereo/{left,right}/image_raw/compressed` | `sensor_msgs/CompressedImage` | `image_bridge` | `RosBridge.Camera.Zenoh` |
| `/stereo/{left,right}/camera_info` | `sensor_msgs/CameraInfo` | Gazebo | perception bridge |
| `/cmd_vel` | `geometry_msgs/Twist` | `teleop_twist_joy`, `drive_test.py` | `AckermannSteering` |
| `/cmd_vel_nav_raw` | `geometry_msgs/TwistStamped` | Nav2 `controller_server`, `behavior_server` | Nav2 `velocity_smoother`, `nav2_test.py` |
| `/cmd_vel_nav` | `geometry_msgs/TwistStamped` | Nav2 `velocity_smoother` | `AckermannSteering` (sim) or `RosBridge.Consumers.Velocity` (vehicle) |
| `/stereo/...` disparity, depth, points, detections | `stereo_msgs`, `sensor_msgs`, `vision_msgs` | perception bridge | Foxglove, `perception_test.py` |
| `/ovcs_heartbeat` | `std_msgs/String` | every Elixir bridge | you, to see the BEAM is alive |

**Two transform buffers, three publishers.** `/tf` is time-indexed: `tf2` stores each sample against its stamp and interpolates. `/tf_static` is timeless, and two things publish on it: `robot_state_publisher` with the URDF's fixed joints, and the bridge with `base_link → stereo_left`, the frame its image headers name. They don't collide, because the URDF's camera frames are `stereo_left_link` and `stereo_left_optical`; the simulated camera and the bridge describe one sensor under different frame names. The bridge's transform is static rather than on `/tf` at a rate because a point cloud stamped after the newest `/tf` sample cannot be transformed, and Nav2 drops it.

**Both `cmd_vel` topics land on one Gazebo topic.** `AckermannSteering` listens on `/model/<app>/cmd_vel`; the two bridges remap the ROS side onto it. Nothing arbitrates, so run teleop *or* Nav2. On the vehicle, `Managers.ControlLevel` decides who has authority.

## Time

The part most likely to bite, because every failure it causes looks like something else.

### Gazebo owns the clock

`use_sim_time: true` means "stamp with `/clock`, not the wall". Gazebo starts its clock at zero and advances it with physics, so a wall-clock stamp (1.79e9 s) sits decades away from everything else. Any consumer comparing stamps across topics drops the message, usually with a `tf2` extrapolation error that reads as a transform problem.

ROS nodes get this from the parameter. The Elixir bridge is not a ROS node, and its drivers stamp frames with Erlang monotonic time, so something has to convert.

### The bridge tracks an offset, not the clock

Each `/clock` sample gives a simulator time and, read alongside it, a local monotonic time; `RosBridge.Clock` stores the difference in `:atomics` for lock-free reads. `RosBridge.Timing.time_message_for/1` projects any monotonic capture time through it:

```text
/clock sample t_sim ─► RosBridge.Clock: offset = t_sim − t_mono ─► :atomics
driver frame (capture_ns, Erlang monotonic) ─► Timing: capture_ns + offset ─► builtin_interfaces/Time
```

Drivers never see simulator time: `Frame.capture_ns` is Erlang monotonic everywhere, and `Timing` is the one place that converts. Without a `/clock` the offset is `nil` and `Timing` stamps wall clock, so the vehicle path is untouched.

### Two monotonic clocks, not one

Erlang's monotonic time is not the kernel's `CLOCK_MONOTONIC`: the VM picks its own zero, about 5.8e17 ns away. libcamera's `SensorTimestamp` is kernel-monotonic. Project one clock's timestamp with the other's offset and it lands decades off, and `builtin_interfaces/Time.sec` is an `int32`, so it wraps negative. `Timing.from_kernel_monotonic/1` converts once, at the driver boundary.

### Why `Clock.init/1` blocks

`RosBridge.Clock` waits for the first `/clock` sample **before returning**, holding up the rest of the supervision tree. `tf2` prunes its buffer relative to its **newest** entry: one wall-clock `/tf_static` message published before the offset is known discards every simulator-time entry that follows and never ages out. Every point cloud afterwards is rejected with

```text
the timestamp on the message is earlier than all the data in the transform cache
```

and the costmaps ignore stereo for the whole run. Measured, the static-transform publisher wins that race by zero milliseconds. Blocking in `init/1`, with `:simulator_clock` listed before the transforms and the camera, makes the race unwinnable.

### Giving up is permanent

If no `/clock` arrives within 60 s (`:acquire_timeout_ms`), the bridge unsubscribes and stays on wall clock for the run. Switching later would be worse: wall-clock stamps would already be in `tf2`'s buffer. The deadline is generous because `docker compose up -d` returns long before Gazebo has loaded a world and spawned the robot.

## Commands: three paths and a gap

Three ways a velocity command reaches a drivetrain. Two exist in the simulator; the third is the vehicle's, and the simulator does not exercise it.

```text
In the simulator
  teleop_twist_joy ──/cmd_vel (Twist)──────────► parameter_bridge ─────┐
  Nav2 velocity_smoother ──/cmd_vel_nav (TwistStamped)► parameter_bridge_nav ─┤
                                            /model/ovcs_mini/cmd_vel ◄──┘
                                            Gazebo AckermannSteering

On the vehicle (OVCS Mini)
  joy node (base station) ──/joy─────────► Consumers.Joy ──0x2B0──► VMS: RosActuatorCommand.*
  Nav2 (onboard) ──/cmd_vel_nav──► Consumers.Velocity ──0x2B1──► VMS: RosVelocityCommand
                                                                       │
                                                             Managers.ControlLevel
                                                                       │
                                          Traxxas.Steering (PWM), Vesc.MotorController (CAN)
  VMS: VehicleMotion ──0x60B──► Publishers.Odometry ◄── BNO085 heading
                                        │ /odom + /tf
                                        ▼
                                   Nav2 (onboard)
```

The simulator loop bypasses the vehicle loop entirely: Nav2's `TwistStamped` goes straight into Gazebo's plugin, which solves the Ackermann kinematics itself. A simulated run proves Nav2 can *plan and command* for a car, and nothing about the VMS converting those commands. `verify-planner-loop` covers that without Gazebo: the vehicle's Nav2 image plans against odometry dead-reckoned by the real bridge from the real VMS's frames, and its commands are asserted on the CAN bus. Only the physics is missing; a Gazebo model driven by the VMS over virtual CAN does not exist.

### The vehicle's own motion (0x60B)

Nav2 consumes `/odom` and the `odom → base_link` transform. On the vehicle, the VMS emits `vehicle_motion` (`0x60B`): the speed `OVCS.VehicleMotion` computes from a driveline rotation through the gearing and wheel size, plus the commanded steering angle, a validity flag and a per-fresh-sample sequence. The OVCS Mini takes a signed rotation from its VESC, cross-checked by a spur pulse sensor; a source that can't sign its rotation takes the sign of the throttle request the control level manager selected.

`RosBridge.Publishers.Odometry` integrates that speed along the BNO085's heading and publishes both topics with one stamp. When the VMS loses its speed, or the frame goes stale, the publisher goes *silent* rather than holding: tf lookups never extrapolate past the newest stamp, so a stopped publisher halts Nav2 instead of letting it plan against a frozen pose.

One odometry owner per fabric: against the simulator Gazebo already publishes `/odom` and the transform, so the OVCS Mini's host bridge drops `:odometry_publisher` when `OVCS_SIM` is set. Two publishers would hand every consumer two contradictory poses.

### The actuator command (0x2B0)

`RosBridge.Consumers.Joy` subscribes to `/joy` and writes `ros_actuator_command`: `steering` and `throttle` as the gamepad's `[-1, 1]` axes at 0.001 resolution, a `direction` (for applications where reverse is a gear and a negative throttle brakes, like OVCS1), and a `sequence`. The VMS components `OVCS.RosActuatorCommand.*` read them as normalised actuator requests: *what a joystick means*, positions, not physics. An axis outside `[-1, 1]` is clamped (Cantastic truncates a signed field silently and the value would come back with the wrong sign), and a `Joy` with too few axes reads as centre.

### The velocity command (0x2B1)

`RosBridge.Consumers.Velocity` subscribes to a velocity topic and writes `ros_velocity_command`: `linear` (m/s, 0.01) and `angular` (rad/s, 0.001) as signed 16-bit integers, plus a `sequence`. This is *what a planner means*: a physical quantity, with the kinematics solved **once, in the VMS**, by `OVCS.RosVelocityCommand` against the application's `geometry/0`:

```text
ω is first clamped to |v| / (wheelbase / tan(steering_limit))
δ = atan(wheelbase · ω / v)      clamped to steering_limit
```

A yaw rate the steering cannot achieve collapses to full lock rather than an error branch. Forward and reverse are the sign of `linear`. The bridge never learns a wheelbase, so any commander (Nav2, a remote operator, a test rig) gets correct kinematics for whatever application it drives.

### The sequence

`Cantastic.Emitter` retransmits a frame at its period whether or not anything new was written, so a frame on time proves only that the bridge is alive. The bridge increments `sequence` once per ROS sample. On the VMS, `RosCommand.Freshness` treats a sequence that stops changing as a lost input and zeroes the throttle or the velocity; a retransmitted frame is never applied as fresh input. The bridge also watches its own input (`RosBridge.InputWatchdog`) to zero what it emits and log why, but the safety decision does not depend on it.

### Two switches, two questions

`Managers.ControlLevel` reads two independent switches on the RC transmitter, because *authority* and *autonomy* are different questions:

| Component | Values | Answers |
|---|---|---|
| `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` | who has authority |
| `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` | which ROS node, when ROS does |

`:ros` means "commands come from the ROS bridge", not "the car drives itself": a human on a gamepad and a planner reach the VMS over identical topics and frames. `:ros` is reachable only from `:radio`, both switches only *request*, and arming `:autonomous` needs a standstill while handing back to `:teleop` is immediate. The state machine, each reference application's channel layout and the bench recipe are in [Your application package](./vehicle_parameterisation.md#control-levels-who-commands-and-which-ros-node).

### Two things that fail silently

- **The wrong message type decodes as nonsense.** `Twist.parse/1` accepts any body of 48 bytes or more, so a 72-byte `TwistStamped` decodes as six float64s read out of the header (denormals near 1.0e-273): the vehicle ignores every command while every watchdog reports a healthy stream. `ZenohClient` warns about surplus bytes after a successful parse, which catches it. The simulator's mirror image: a `Twist` bridge fed `TwistStamped` never fires, and a healthy-looking Nav2 moves nothing.
- **A quiet commander leaves its last command on the bus.** The emitter retransmits on a timer; the `sequence` above is the defence.

## Nav2, as configured here

Nav2 1.5.1: a lifecycle manager and four servers (`controller_server`, `planner_server`, `behavior_server`, `bt_navigator`) plus `velocity_smoother`. Not `nav2_bringup`, which is absent from the Lyrical archive and would pull in map_server and AMCL.

One configuration, three deployments. The parameter file, behaviour trees and launch file live in `compose/compute/nav2/`; the image is `compose/compute/images/nav2/`, tagged `ovcs/nav2:lyrical` wherever it is built.

| Where | Compose | Clock |
|---|---|---|
| The vehicle's compute node | `compose/compute/docker-compose.yml`, always on | wall |
| A dev machine, against a host VMS and bridge | `compose/local/base.yml --profile nav2` | wall |
| Against the simulator | `compose/local/simulation.yml --profile nav2` | `use_sim_time:=true` |

The file holds the vehicle's values (`use_sim_time: false`); the simulator overrides the clock with a launch argument rather than keeping a copy that would drift.

```text
NavigateToPose goal ─► bt_navigator ─► planner_server (NavFn) ─► path
                                   └─► controller_server (MPPI) ◄─ /odom, /tf, costmaps (inflation only)
controller_server, behavior_server ─/cmd_vel_nav_raw─► velocity_smoother ─/cmd_vel_nav @ 20 Hz─►
```

What is deliberately unusual:

- **No map, no AMCL.** Every frame is `odom` and both costmaps roll with the vehicle: enough to prove the velocity path drives an Ackermann vehicle without the SLAM question, and no fake static `map → odom`, which looks like localisation and is not.
- **Costmaps are inflation-only.** No obstacle source: the car does not yet avoid what stereo sees.
- **`AckermannConstraints`.** MPPI's `motion_model` names a plugin *instance*; the class, `mppi::AckermannMotionModel`, comes from `<instance>.plugin`. It clamps yaw rate to `|vx| / min_turning_r` inside the sampler, so infeasible arcs are never considered. `min_turning_r` is `0.324 / tan(0.52) = 0.566 m`, rounded up to 0.6.
- **`TwistStamped` on `/cmd_vel_nav`.** `nav2_util::TwistPublisher` defaults `enable_stamped_cmd_vel` to true; its header comment says otherwise, and the code wins.
- **A 0.22 m/s floor.** Below its minimum ERPM the Mini's VESC brakes instead of driving, 0.22 m/s through the gearing ([VESC drivetrain](./vesc_drivetrain.md)). `velocity_smoother` has a `deadband_velocity` of 0.22 m/s, so a slower linear velocity goes out as zero. BackUp runs at 0.25 m/s, and BackUp and DriveOnHeading floor at `minimum_speed: 0.25`, for the same reason.
- **No `Spin` in either behaviour tree.** A car produces no motion from a spin, so it ran its full duration and burned a recovery slot. The spin *server* stays loaded because `bt_navigator` resolves every action at activation.
- **NavFn, not Smac.** No `nav2_smac_planner` in the archive, so the global plan knows nothing about turning radius; MPPI carries the corners the car cannot cut.
- **`yaw_goal_tolerance` is 3.15.** A car cannot rotate in place to a final heading.

### Arriving proves almost nothing

Gazebo's `AckermannSteering` quietly ignores commands it cannot execute. With `mppi::DiffDriveMotionModel` substituted in, the vehicle reached the tight goal *better* than the correct configuration (0.30 m against 0.53 m) while commanding **3.68×** the kinematic yaw-rate limit. So `nav2_test.py` asserts on what was *commanded*, and uses two goals because no single goal tests both arrival and the limits.

## Perception against the simulator

The whole stereo stack (SGBM, rectification, publishers, detector) runs **unchanged** against Gazebo. One module differs:

```text
Gazebo cameras ─► image_bridge ─/stereo/{left,right}/image_raw/compressed─► RosBridge.Camera.Zenoh
  ─► StereoCamera.Supervisor ─► StereoCamera.OpenCV (SGBM) ─► Publishers.StereoCamera ─► fabric
                             └─► detector (optional: Stub or Dnn) ─► /stereo/detections
```

`RosBridge.Camera.Zenoh` subscribes to a `CompressedImage` topic and emits the same `{:camera_frame, %Frame{}}` casts a physical driver does. Swapping it in for `RosBridge.Camera.LibCamera` is the entire difference between the car and the simulated car; in the OVCS Mini, `OVCS_SIM=1` selects it (`perception_sim_config/0` in `vehicles/ovcs_mini/lib/ovcs_mini.ex`).

- **Compressed, not raw.** A 480×270 rgb8 frame is 389 KB; at 30 Hz, 11.6 MB/s. Over Zenoh, a subscriber that cannot drain that receives one frame every fifteen seconds, which looks like a dead topic. JPEG is about 6.5 KB a frame. Compression belongs upstream of the fabric, as on the vehicle.
- **The simulator has its own calibration.** Gazebo renders an ideal pinhole; the vehicle's distortion coefficients and rectification rotations warp its views apart. `vehicles/ovcs_mini/priv/calibration/sim/` has D = 0 and R = I: 61.2 % coverage on the same scene, against 5.4 % with the vehicle's calibration.
- **One topic name, two roles.** `Publishers.StereoCamera` republishes each frame on `<topic_prefix>/<side>/image_raw/compressed`, and the prefix is `stereo`, so against the simulator the bridge publishes onto the name it consumes from `image_bridge`. The measured 30 Hz suggests a session does not hear its own publications; if the stereo rate ever looks doubled, look here first.
- **`workshop.sdf`, not `empty.sdf`, for depth.** SGBM correlates texture; a flat plane under a blank sky yields no disparity.

Detection on the Hailo-8 and its backends are in [Perception: object detection](./ros_perception_detection.md).

## Per-application bridge configuration

This is the framework/application boundary on the ROS side. Apart from `ZenohClient`, every feature of `RosBridge` is a component the application opts into through `%RosBridge.Config{}`, returned by its `ros_bridge_config(:host | :target, firmware_id)`. The host arm is where a dummy IMU lets `./ovcs run` work without a sensor; the target arm has the real `BNO085.I2C`. From the OVCS Mini reference application:

```elixir
defp ros_target_config,
  do: %RosBridge.Config{
    zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
    node_name: "ovcs_bridge_ros",
    components: [
      :heartbeat,
      :joy_interpreter,
      {:velocity_interpreter,
       %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
      {:imu_publisher, driver: BNO085.I2C},
      {:odometry_publisher, driver: BNO085.I2C}
    ]
  }
```

A bare atom is shorthand for `{atom, []}`, and an unknown name raises at supervisor boot. The components are `:heartbeat`, `:simulator_clock`, `:joy_interpreter`, `:velocity_interpreter`, `:imu_publisher`, `:odometry_publisher`, `:static_transforms`, `:stereo_camera`, `:detector` and `:hailo_detector` (after `:stereo_camera`); `RosBridge.Components` documents each. Order matters where one component listens to another: `:odometry_publisher` after `:imu_publisher`. Two bridges on one fabric need distinct `node_name`s, or they collide in the ROS graph and Foxglove renders them as one node; the Mini uses `ovcs_bridge_ros` and `ovcs_bridge_perception`.

## Version pins

These move together. The `pins` job in `.github/workflows/ros2.yml` fails when the zenoh ones disagree.

| What | Value | Where |
|---|---|---|
| zenoh router image | `eclipse/zenoh:1.9.0` | `compose/compute/docker-compose.yml`, `compose/local/base.yml` |
| zenoh Python client | `eclipse-zenoh==1.9.0` | `compose/compute/images/ros2/Dockerfile` |
| zenoh in the Elixir bridge | `zenohex ~> 0.9.0` (zenoh 1.9.0) | `bridges/ros_bridge/mix.exs` |
| ROS 2 distribution | `ros:lyrical-ros-base` | `compose/compute/images/{ros2,nav2}/`, `compose/local/images/sim/` |
| Gazebo | Jetty, via `ros-lyrical-ros-gz` | `compose/local/images/sim/Dockerfile` |

## The verifiers

Each is one command: it brings the stack up, asserts, and tears it down. Each exists because it caught something that looked fine on screen.

| Task | Script | Proves | What `/odom` alone could not |
|---|---|---|---|
| `mise run verify-drivetrain` | `drive_test.py` | wheel radius, wheelbase, steering geometry | a wrong wheel radius cancels inside `AckermannSteering`: `/odom` reports 1.000 m/s while the car crawls at 0.548. The check reads `/joint_states`. |
| `mise run verify-nav2` | `nav2_test.py` | Nav2 arrives at an easy goal **and** commands within the Ackermann limits at a tight one | an unconstrained controller arrives *better* while commanding 3.68× the limit |
| `mise run verify-perception` | `perception_test.py` | depth median, p75 and p95 match the world's box positions to a centimetre; fused detection depth | geometry is checked tightly; rates only against a floor |
| `mise run verify-planner-loop` | `verify_planner_loop.sh` | no simulator: the vehicle's Nav2 image plans against `/odom` dead-reckoned by the host bridge from the host VMS's `0x60B`, and a goal produces nonzero `0x2B1` on vcan | the VMS-side conversion path, which Gazebo's loop bypasses |

Each script starts the standalone router and the simulator, waits, starts Nav2 or the perception bridge, waits again, pipes the test into the base stack's `ros2` container, then tears down, the BEAM first because it holds a Zenoh session. The waits are fixed `sleep 20` / `sleep 30` / `sleep 25`: a slower machine can fail a verifier without anything being wrong. `KEEP_UP=1` leaves the stack running. `verify-perception` also needs the `mise` toolchain and a `vcan0`, because it runs the real Elixir bridge and Cantastic will not start without a CAN network.

## Verifying end to end

With `./ovcs run <app>` going and the `compose/local/base.yml` stack up:

```sh
cd compose/local && docker compose -f base.yml exec ros2 bash -lc '
  ros2 topic list
  ros2 topic info -v /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

Or open Foxglove Studio against `ws://<docker-host>:8765` and subscribe to `/ovcs_heartbeat`. Two layouts ship in `compose/local/foxglove/`: `ovcs_navigation.json` for the planner and `ovcs_perception.json` for the stereo pipeline.

> [!TIP]
> If `ros2 topic echo` fails with `ResponseError: unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'` (a `ros2cli` daemon bug on Python 3.14), pass `--no-daemon`.

## Reading map

| To understand | Read | Then |
|---|---|---|
| how to run any of this | [Simulation](../compose/local/simulation/README.md) | `compose/local/simulation.yml` |
| the launch order and bridged topics | `compose/local/simulation/launch/sim.launch.py` (its docstrings are the design notes) | `compose/compute/nav2/launch/nav2.launch.py`, `compose/local/simulation/launch/teleop.launch.py` |
| the rmw_zenoh wire format | [`bridges/ros_bridge/README.md`](../bridges/ros_bridge/README.md) | `bridges/ros_bridge/lib/ros2/rmw_zenoh.ex`, `zenoh_client.ex` |
| time | `bridges/ros_bridge/lib/ros_bridge/clock.ex` | `timing.ex`, `publishers/static_transform.ex` |
| what an application's bridge runs | `vehicles/ovcs_mini/lib/ovcs_mini.ex` (`ros_bridge_config/2`) | `bridges/ros_bridge/lib/ros_bridge/components.ex` |
| the actuator command path | `bridges/ros_bridge/lib/ros_bridge/consumers/joy.ex` | `libraries/ovcs_can/priv/can/components/ovcs/0x2B0_ros_actuator_command.yml`, `vms/core/lib/vms_core/components/ovcs/ros_actuator_command/` |
| the velocity command path | `bridges/ros_bridge/lib/ros_bridge/consumers/velocity.ex` | `0x2B1_ros_velocity_command.yml`, `vms/core/lib/vms_core/components/ovcs/ros_velocity_command.ex` |
| odometry on the vehicle | `bridges/ros_bridge/lib/ros_bridge/publishers/odometry.ex` | `0x60B_vehicle_motion.yml`, `vms/core/lib/vms_core/components/ovcs/vehicle_motion.ex` |
| who commands the vehicle | [Your application package](./vehicle_parameterisation.md#control-levels-who-commands-and-which-ros-node) | `vms/core/lib/vms_core/managers/control_level.ex` |
| Nav2's configuration | `compose/compute/nav2/config/nav2.yaml` (heavily commented) | `nav2_ackermann_bt.xml` beside it, `compose/local/simulation/scripts/nav2_test.py` |
| the perception pipeline | [Perception: object detection](./ros_perception_detection.md) | `bridges/ros_bridge/lib/ros_bridge/camera/zenoh.ex`, `stereo_camera/supervisor.ex` |
| the vehicle's ROS computer | [ROS compute node](./ros_compute_node.md) | `compose/compute/`, [`compose/README.md`](../compose/README.md) |
| the model's geometry | `vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro` | `gazebo_ackermann.xacro`, `OvcsMini.geometry/0` |
