---
title: Simulation
description: Drive the OVCS Mini reference application in Gazebo with nothing but Docker, then point the real perception pipeline and Nav2 at it.
---

A Gazebo **Jetty** model of the OVCS Mini reference application (a Traxxas Slash 4x4, 1/10 scale) and the container stack to run it. It needs Docker and Compose v2 and nothing else: no Nerves toolchain, no CAN interface, no vehicle. It is the quickest way to see OVCS do something.

> [!NOTE]
> The simulator stack is framework tooling. It knows nothing about the Mini beyond the model mounted into it, which lives in the Mini's own package, `vehicles/ovcs_mini/description/`. Your application gets its own model the same way. See [Framework and applications](../../../docs/framework.md).

> [!WARNING]
> The gamepad and Nav2 drive Gazebo's physics **directly**. The VMS and the CAN bus are **not in that loop**; the Elixir bridge runs against the simulator only for perception (and, on the host ROS bridge, the IMU). A CAN frame is not what moves the simulated car. [ROS 2 and the simulator](../../../docs/ros2_integration.md#commands-three-paths-and-a-gap) shows both loops.

## What it is

The simulator speaks Zenoh like everything else, so a simulated vehicle appears on the same fabric as a real one, and `ros2 topic`, Foxglove and the rest need no special case. It lives in `compose/local/` beside the operator's stack because, like it, it never runs on the car.

```text
compose/local/
  simulation.yml          the stack: sim, teleop, gz-gui, nav2
  images/sim/             the Gazebo Jetty image
  simulation/             worlds, shared macros, sim.launch.py, gamepad mapping, test scripts
  scripts/verify_*.sh     the verifiers behind `mise run verify-*`

vehicles/ovcs_mini/
  description/            the Mini's URDF/xacro model, mounted into the container
```

A model describes one application, so it lives with that application's package. Simulating yours is a `description/` directory under `vehicles/<app>/` containing `<app>.urdf.xacro`, one mount line in `simulation.yml`, and:

```sh
docker compose -f simulation.yml exec sim ros2 launch /opt/ovcs/launch/sim.launch.py vehicle:=<app>
```

## Quickstart

Every command runs from `compose/local/`. The stacks are named files, so `-f` is always spelled out. The first run pulls and builds images; budget a few minutes.

```sh
cd compose/local

# A Zenoh router, if there is no vehicle on the LAN to peer with.
docker compose -f base.yml --profile standalone up -d zenohd

docker compose -f simulation.yml up -d          # the simulator, headless
docker compose -f simulation.yml logs -f sim    # ^C once it settles
```

Drive it from a topic:

```sh
docker compose -f simulation.yml exec sim bash -lc \
  'ros2 topic pub -r 10 /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 1.0}, angular: {z: 0.3}}"'
```

Watch it move, in another shell:

```sh
docker compose -f simulation.yml exec sim bash -lc 'ros2 topic echo /odom --once'
```

See it. The GUI is a separate service, because Qt in a headless container takes the physics down with it; a plain `up -d` works on a machine with no display:

```sh
xhost +local:docker
docker compose -f simulation.yml --profile gui up -d gz-gui
```

Tear down with `docker compose -f simulation.yml down`, plus `docker compose -f base.yml rm -sf zenohd`.

> [!TIP]
> If `ros2 topic echo` fails with `ResponseError: unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'` (a `ros2cli` daemon bug on Python 3.14), pass `--no-daemon`: `ros2 topic echo --no-daemon /odom`.

## Then, in order of how much each adds

| | Command | What it gives you | Needs |
|---|---|---|---|
| gamepad | `docker compose -f simulation.yml --profile teleop up -d teleop` | drive with a stick instead of `topic pub` | a joystick at `/dev/input/js0` |
| drivetrain | `mise run verify-drivetrain` | odometry checked against the model's geometry | Docker |
| navigation | `mise run verify-nav2` | Nav2 planning and driving to a goal | Docker |
| depth | `mise run verify-perception` | the **real** stereo pipeline, checked against the world | Docker, `mise`, `vcan0` |

The `verify-*` tasks bring the whole stack up, assert, and tear it down: one command that passes or tells you what broke. `KEEP_UP=1` leaves the stack running to poke at.

`verify-perception` runs the actual Elixir perception bridge rather than a ROS node, so it needs the `mise` toolchain and a `vcan0`, since Cantastic will not start without a CAN network. It checks for `vcan0` up front and tells you if it is missing:

```sh
mise run cli                  # builds ./ovcs, needs Rust
./ovcs can setup ovcs_mini    # creates vcan0, needs sudo
```

> [!WARNING]
> Stop driving before you verify. Nothing arbitrates `/cmd_vel`: a `topic pub` left running, or the teleop service, publishes against the verifier's own commands, and the failure does not name the cause. `^C` the publisher or run `docker compose -f simulation.yml stop teleop` first. Nav2 uses a separate topic and does not collide.

## What the verifiers prove

### Drivetrain

```sh
docker compose -f simulation.yml exec sim python3 /opt/ovcs/scripts/drive_test.py
```

```text
straight: 1.0 m/s        ->  1.000 m/s     wheel radius and odometry scale
turn 1.0 m/s, 0.5 rad/s  ->  R = 2.005 m   wheelbase and steering geometry
turn 2.0 m/s, 0.5 rad/s  ->  R = 3.984 m   the above, at a second point
```

The turning radius must equal `v / ω`; it exercises wheelbase, track and kingpin width together.

Driving at 1 m/s and checking that `/odom` agrees proves nothing. The wheel radius cancels inside Gazebo's `AckermannSteering`: the commanded speed is divided by it to get a joint velocity, and the joint velocity is multiplied by it again to get odometry. With the radius set to 0.1 against the real 0.0548, `/odom` reports 1.000 m/s while the wheels turn at 10.0 rad/s and the car crawls at 0.548. So the test reads `/joint_states`, the physical joint velocity, and multiplies by the real radius: in a good run, `18.25 rad/s × 0.0548 m = 1.000 m/s`.

Two traps in measuring it:

- **Arc, not chord.** Once the path curves, the displacement between start and end pose is not the distance travelled. Over a 199° turn the chord is 0.57× the arc, which reads like the car driving at half speed.
- **Unwrapped yaw.** A quaternion converts to a heading in `[-π, π]`, so subtracting first from last silently loses a whole turn or flips its sign.

### Perception

```sh
mise run verify-perception                     # stereo only
OVCS_DETECTOR=stub mise run verify-perception  # + the depth-fusion check
```

It starts the router, the simulator and the real perception bridge, measures for 20 s, checks, and tears down. The expected distances are derived from `worlds/workshop.sdf` and the model, not recorded, so moving a box or the camera updates the expectation:

```text
box_1m     x=1.0, 0.3 deep  ->  front face 0.85 m from origin
box_2m     x=2.0, 0.4 deep  ->  1.80 m
back_wall  x=6.0, 0.2 deep  ->  5.90 m
camera_x = wheelbase/2 - 0.120 = 0.042 m
```

That gives 0.808 m, 1.758 m and 5.858 m from the lens. A good run:

```text
  PASS  depth median: 0.810 m, world says 0.808 (tolerance 0.050)
  PASS  depth p75: 1.754 m, world says 1.758 (tolerance 0.100)
  PASS  depth p95 within the room: 5.847 m, back wall at 5.858
  PASS  fused detection depth: 0.809 m, world says 0.808 (tolerance 0.050)
```

Geometry is checked tightly because it is machine-independent: a median of 0.808 m means the disparity scale, the rectification and the intrinsics all agree with the world. Throughput depends on the CPU and on whether Gazebo is software-rendering, so rates are checked against a floor that means "the pipeline is running". Halving `@disparity_fixed_point_scale` in `StereoCamera.OpenCV`, a plausible edit invisible on screen, fails exactly the depth checks:

```text
  FAIL  depth median: 0.405 m, world says 0.808
  FAIL  depth p75: 0.877 m, world says 1.758
  FAIL  fused detection depth: 0.404 m, world says 0.808
  PASS  disparity rate / encoding / coverage / point cloud
```

The checks tell "slow" from "wrong".

## Running the perception bridge against it

The stereo stack (SGBM, rectification, publishers, detector) is framework code in `bridges/ros_bridge` and runs unchanged against the simulator. The Mini wires it in its `ros_bridge_config/2`; `VEHICLE=OvcsMini` below selects that application, and yours is selected the same way. Only the camera driver differs: `RosBridge.Camera.Zenoh` subscribes to a ROS image topic and emits the same frames a physical driver does.

```sh
./ovcs can setup ovcs_mini          # once; Cantastic needs vcan0 to exist

cd bridges/firmware
VEHICLE=OvcsMini OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_perception CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  iex -S mix
```

Three details fail misleadingly if wrong:

- **Start from `bridges/firmware`, not `bridges/ros_bridge`.** The library has no `config/`, so `CAN_NETWORK_MAPPINGS` is never read there and Cantastic dies with "CAN network mappings are missing from the Cantastic configuratiion". The firmware project is what `./ovcs run` starts; its `config/runtime.exs` consumes the variable.
- **`BRIDGE_FIRMWARE_ID=ros_perception` is required.** On the host it otherwise defaults to `radio_control`, so no ROS bridge starts at all.
- **`OVCS_SIM=1` selects the simulated wiring**, so it cannot be picked up by accident on the vehicle. No Hailo detector there, since a workstation has no accelerator; `OVCS_DETECTOR` picks a backend instead ([Perception: object detection](../../../docs/ros_perception_detection.md)).

Measured against `workshop.sdf`: 30.3 Hz, 61.2 % depth coverage, median depth 0.81 m and p75 1.75 m, on the world's two boxes.

Two things produce **no disparity at all**:

- **An untextured world.** SGBM correlates local patches; a flat plane under a blank sky gives it nothing. `empty.sdf` is for driving tests only; use `workshop.sdf` for anything involving depth.
- **The vehicle's own calibration.** Gazebo renders an ideal pinhole, and real distortion coefficients and rectification rotations warp the views apart: 5.4 % coverage. The simulator's calibration, `vehicles/ovcs_mini/priv/calibration/sim/`, has D = 0 and R = I, with the real focal length scaled to the capture resolution: the optics match the vehicle, the distortion model matches the simulator.

## Navigating with Nav2

```sh
mise run verify-nav2            # up, navigate, check, down
KEEP_UP=1 mise run verify-nav2  # leave the stack up

# or by hand
docker compose -f simulation.yml --profile nav2 up -d nav2
docker logs -f ovcs-nav2
```

This is Nav2 1.5.1 in the **vehicle's own image** (`compose/compute/images/nav2/`, tagged `ovcs/nav2:lyrical`), with the vehicle's parameters and behaviour trees mounted in, behind a profile so a plain `up -d` stays a bare simulator. The one difference is the clock, a visible launch argument (`use_sim_time:=true`). No map and no AMCL: every frame is `odom` and both costmaps roll with the vehicle.

The controller and behaviours publish `/cmd_vel_nav_raw`; `velocity_smoother` republishes it on `/cmd_vel_nav` with a deadband that sends any linear velocity under 0.22 m/s as zero, the Mini's VESC floor ([VESC drivetrain](../../../docs/vesc_drivetrain.md)). Gazebo would drive slower; the deadband is there to run the vehicle's configuration. `nav2_test.py` checks the controller's own output on `/cmd_vel_nav_raw`.

### Four things that fail silently

- **Nav2 publishes `TwistStamped`.** `nav2_util::TwistPublisher` defaults `enable_stamped_cmd_vel` to true, whatever its header comment says. The `/cmd_vel` bridge is unstamped, so Nav2 has its own topic (`/cmd_vel_nav`) and its own bridge node onto the same Gazebo topic. Without it, a healthy-looking Nav2 moves nothing.
- **`motion_model` names a plugin instance, not a class.** The class comes from `<instance>.plugin`; naming the class directly fails with "No 'plugin' param for param ns!". Leaving `motion_model` unset fails loudly: MPPI defaults it to `diff_drive`, which has no `.plugin`, so the controller refuses to configure.
- **The odometry frame needs `<frame_id>`.** Without it `AckermannSteering` namespaces the frame by model name (`ovcs_mini/odom`), Nav2 rejects it, and every costmap logs `Invalid frame ID "odom"` and never activates. `gazebo_ackermann.xacro` sets `odom` / `base_link`, at 50 Hz.
- **`Spin` aborts navigation on a car.** Both stock behaviour trees put it in their recovery branch; an Ackermann vehicle produces no motion from a spin, so it runs its full duration and burns a recovery slot. Both trees drop it. The spin *server* stays loaded because `bt_navigator` resolves every action at activation.

### Arriving proves almost nothing

`AckermannSteering` quietly ignores commands it cannot execute, so a controller configured for a differential-drive robot still arrives while commanding arcs the steering could never cut. With `mppi::DiffDriveMotionModel` substituted in, the vehicle reached the tight goal *better* than the correct configuration (0.30 m against 0.53 m) while commanding a yaw rate 3.68× the kinematic limit. So `nav2_test.py` asserts on what was **commanded**, with two goals because no single goal tests both:

| Goal | Required arc | Asserts |
|---|---|---|
| 3.0 m ahead, 1.0 m across | 5.00 m | arrival |
| 0.8 m ahead, 1.4 m across | 0.93 m | the kinematic limits |

An easy goal never approaches the radius limit: an unconstrained controller drives it at 0.74×, under the threshold. A tight goal bites, but the correct configuration then has to shuffle and may not arrive, so arrival is reported rather than asserted there.

## The model

`vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro` declares every dimension once. Measured values come from the Traxxas specification; **ESTIMATE** marks what it doesn't publish (tyre width, chassis tub, ground clearance, steering lock, the mass split between chassis and wheels). Those are the numbers to revisit first if the model behaves oddly.

| | Slash 4x4 |
|---|---|
| Wheel radius | 0.0548 m (109.5 mm tyre) |
| Track | 0.296 m |
| Wheelbase | 0.324 m |
| Vehicle mass | 2.41 kg |

The chassis carries its mass in a low tub rather than the full 193 mm envelope, because a centre of gravity at half the body height rolls the truck over in its first corner. Drive is Gazebo's own `AckermannSteering` system, reached through `ros_gz_bridge`. `inertial_macros.xacro` and the gamepad mapping in `config/` come from the earlier [traxxas](https://github.com/open-vehicle-control-system/traxxas) model, which targeted Gazebo Classic.

The model carries the stereo pair and a simulated BNO085 on `/imu_raw`. The camera bar's **height** (`camera_z`, 0.12 m) is the one unmeasured number, in the model and in the vehicle's `stereo_transforms` alike.

## Why Jetty, and why Lyrical

ROS 2 Jazzy supports only Gazebo Harmonic; Jetty, the current LTS, needs ROS 2 **Lyrical**, so the whole ROS stack is on Lyrical. The move changed nothing on the wire: all 14 hardcoded `RIHS01_` type hashes in `ros_bridge` are identical between Jazzy and Lyrical, and zenoh is 1.9.0 on both sides, the version `zenohex` 0.9 pins. The Elixir side speaks the rmw_zenoh protocol directly and links nothing from ROS.

## Known limitations

- Global plans come from NavFn (`nav2_smac_planner` is absent from the Lyrical archive), so they are **not kinematically feasible**: MPPI carries the corners the car cannot cut. Fine in an open workshop, a real constraint in tight spaces.
- `yaw_goal_tolerance` is deliberately about π. A car cannot rotate to a commanded final heading.
- Nothing arbitrates between `/cmd_vel` and `/cmd_vel_nav`. Run teleop or Nav2, not both.
- The verifiers wait with fixed `sleep`s; a slow machine can fail one without anything being wrong.
