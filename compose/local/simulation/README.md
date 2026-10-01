---
title: Simulation
description: Drive the OVCS Mini reference vehicle in Gazebo with nothing but Docker, then point the real perception pipeline and Nav2 at it.
---

A Gazebo **Jetty** model of the OVCS Mini reference vehicle (a Traxxas Slash 4x4, 1/10 scale) and the container stack to run it. It needs Docker and Compose v2 and nothing else: no Nerves toolchain, no CAN interface, no physical vehicle. It is the quickest way to see OVCS do something.

> [!NOTE]
> The simulator stack is framework tooling. It knows nothing about the Mini beyond the model mounted into it, which lives in the Mini's own package, `vehicles/ovcs_mini/description/`. Your vehicle gets its own model the same way. See [Framework and vehicles](../../../docs/framework.md).

> [!WARNING]
> The gamepad and Nav2 drive Gazebo's physics **directly**. The VMS and the CAN bus are **not in that loop**; the Elixir bridge runs against the simulator only for perception (and, on the host ROS bridge, the IMU). A CAN frame is not what moves the simulated car. [ROS 2 and the simulator](../../../docs/ros2_simulator.md#commands-three-paths-and-a-gap) shows both loops.

## What it is

The simulator speaks Zenoh like everything else, so a simulated vehicle appears on the same fabric as a real one, and `ros2 topic`, Foxglove and the rest need no special case. It lives in `compose/local/` beside the operator's stack because, like it, it never runs on the car.

```text
compose/local/
  simulation.yml          the stack: sim, teleop, gz-gui, nav2, rtabmap, explore
  images/sim/             the Gazebo Jetty image
  simulation/             worlds, shared macros, sim.launch.py, gamepad mapping, test scripts
  scripts/verify_*.sh     the verifiers behind `mise run verify-*`

vehicles/ovcs_mini/
  description/            the Mini's URDF/xacro model, mounted into the container
```

A model describes one vehicle, so it lives with that vehicle's package. Simulating yours is a `description/` directory under `vehicles/<vehicle>/` containing `<vehicle>.urdf.xacro`, a mount line in `simulation.yml` (`- ../../vehicles/<vehicle>/description:/opt/ovcs/vehicles/<vehicle>:ro`), and `vehicle:=<vehicle>` added to the `sim` service's command:

```sh
ros2 launch /opt/ovcs/launch/sim.launch.py teleop:=false vehicle:=<vehicle>
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
docker compose -f simulation.yml exec sim bash -c \
  'source /opt/ros/lyrical/setup.bash && ros2 topic pub -r 10 /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 1.0}, angular: {z: 0.3}}"'
```

Watch it move, in another shell:

```sh
docker compose -f simulation.yml exec sim bash -c 'source /opt/ros/lyrical/setup.bash && ros2 topic echo /odom --once'
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
| navigation | `mise run verify-nav2` | isolated Nav2 exploration, arrival and sensor-loss checks | Docker |
| depth | `mise run verify-perception` | the **real** stereo pipeline, checked against the world | Docker, `mise`, `vcan0` |

`verify-nav2` uses network-isolated containers with a synthetic Ackermann plant and map/cloud source. It saves logs and JSON results in a temporary directory. The Gazebo `verify-*` tasks bring their stack up, assert, and tear it down; `KEEP_UP=1` leaves those stacks running.

`verify-perception` runs the actual Elixir perception bridge rather than a ROS node, so it needs the `mise` toolchain and a `vcan0`, since Cantastic will not start without a CAN network. It checks for `vcan0` up front and tells you if it is missing:

```sh
mise run cli                  # builds ./ovcs, needs Rust
./ovcs can setup ovcs_mini    # creates vcan0, needs sudo
```

> [!WARNING]
> Stop driving before you verify. Nothing arbitrates `/cmd_vel`: a `topic pub` left running, or the teleop service, publishes against the verifier's own commands, and the failure does not name the cause. `^C` the publisher or run `docker compose -f simulation.yml stop teleop` first. Nav2 has its own ROS topic, `/cmd_vel_nav`, but both bridges drive the same Gazebo command topic, so run only one commander in an interactive Gazebo session. The isolated `verify-nav2` test cannot receive these commands.

## Mapping and exploration in Gazebo

Start the real perception bridge described below, then start the mapper,
Nav2 and the idle exploration container on the same local fabric:

```sh
docker compose -f simulation.yml --profile mapping --profile nav2 --profile explore up -d rtabmap nav2 explore
```

Both mapping and navigation use Gazebo's clock. Manually map a clear
staging area, stop the manual commander, then start the supervisor:

```sh
docker compose -f simulation.yml exec explore bash -lc \
  'ros2 launch /opt/ovcs/launch/explore.launch.py use_sim_time:=true'
```

`dry_run:=true` shows candidate viewpoints without goals. The simulation
mapper explicitly starts a new database at each start; the vehicle keeps
its database. A mapper restart stops exploration in either case.

## What the verifiers prove

### Drivetrain

```sh
docker compose -f simulation.yml exec sim bash -c 'source /opt/ros/lyrical/setup.bash && python3 /opt/ovcs/scripts/drive_test.py'
```

```text
straight: 1.0 m/s        ->  1.000 m/s     wheel radius and odometry scale
turn 1.0 m/s, 0.5 rad/s  ->  R = 2.032 m   wheelbase and steering geometry
turn 2.0 m/s, 0.5 rad/s  ->  R = 3.927 m   the above, at a second point
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

It starts the router, the base `ros2` container (where the checks run), the simulator and the real perception bridge, measures for 20 s, checks, and tears down. Moving a box or the camera means updating the constants in `perception_test.py`; until then the check fails. The expected distances are computed from constants copied out of `worlds/workshop.sdf` and the model, not from a recorded run:

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

The stereo stack (SGBM, rectification, publishers, detector) is framework code in `bridges/ros_bridge` and runs unchanged against the simulator. The Mini wires it in its `ros_bridge_config/2`; `VEHICLE=OvcsMini` below selects that vehicle, and yours is selected the same way. Only the camera driver differs: `RosBridge.Camera.Zenoh` subscribes to a ROS image topic and emits the same frames a physical driver does.

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
- **`OVCS_SIM=1` selects the simulated wiring**, so it cannot be picked up by accident on the vehicle. No Hailo detector there, since a workstation has no accelerator; `OVCS_DETECTOR` picks a backend instead ([Perception: object detection](../../../docs/ros2_perception.md)).

Measured against `workshop.sdf`: 30.3 Hz, 61.2 % depth coverage, median depth 0.81 m and p75 1.75 m, on the world's two boxes.

Two things produce **no disparity at all**:

- **An untextured world.** SGBM correlates local patches; a flat plane under a blank sky gives it nothing. `empty.sdf` is for driving tests only; use `workshop.sdf` for anything involving depth.
- **The vehicle's own calibration.** Gazebo renders an ideal pinhole, and real distortion coefficients and rectification rotations warp the views apart: 5.4 % coverage. The simulator's calibration, `vehicles/ovcs_mini/priv/calibration/sim/`, has D = 0 and R = I, with the real focal length scaled to the capture resolution: the optics match the vehicle, the distortion model matches the simulator.

## Navigating with Nav2

```sh
mise run verify-nav2
```

The offline verifier uses the vehicle's Nav2 image with the same parameters,
behavior trees, supervisor and guard. It runs in `--network none` containers
and saves logs and JSON results. It requires completed viewpoints and checks
commands against the Ackermann limits, map occupancy and mission perimeter.
The dead-end case must complete one short retreat over the driven route;
cloud and explorer losses are also injected during reverse motion. Sensor,
TF and explorer losses must stop motion. The synthetic plant includes
steering-rate limits, acceleration and the 0.08 m/s drive deadband.

For an interactive Gazebo run, follow [mapping and exploration](#mapping-and-exploration-in-gazebo)
above. Navigation requires the map, stereo cloud, odometry and transforms;
there is no mapless navigation mode. `/cmd_vel_nav_raw` passes through the
smoother and independent guard before becoming `/cmd_vel_nav` (`TwistStamped`).
The vehicle configuration is documented in [ROS 2 and the simulator](../../../docs/ros2_simulator.md#nav2-as-configured-here).

## The model

`vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro` declares every dimension once. Measured values come from the Traxxas specification; **ESTIMATE** marks what it doesn't publish (tyre width, chassis tub, ground clearance, steering lock, the mass split between chassis and wheels). Those are the numbers to revisit first if the model behaves oddly.

| | Slash 4x4 |
|---|---|
| Wheel radius | 0.0548 m (109.5 mm tyre) |
| Track | 0.296 m |
| Wheelbase | 0.324 m |
| Vehicle mass | 2.41 kg |

The chassis carries its mass in a low tub rather than the full 193 mm envelope, because a centre of gravity at half the body height rolls the truck over in its first corner. Drive is Gazebo's own `AckermannSteering` system, reached through `ros_gz_bridge`. `inertial_macros.xacro` and the gamepad mapping in `config/` come from the earlier [traxxas](https://github.com/open-vehicle-control-system/traxxas) model, which targeted Gazebo Classic.

The model carries the stereo pair and a simulated BNO085 on `/imu_raw`. The camera bar is configured at 0.185 m above ground in the model and the vehicle transform. Recheck sensor extrinsics after changing the mounting.

## Why Jetty, and why Lyrical

ROS 2 Jazzy supports only Gazebo Harmonic; Jetty, the current LTS, needs ROS 2 **Lyrical**, so the whole ROS stack is on Lyrical. The move changed nothing on the wire: all 14 `RIHS01_` type hashes `ros_bridge` carried over from Jazzy are identical on Lyrical (the 15th, `nav_msgs/msg/Odometry`, was captured on Lyrical directly), and both sides run zenoh 1.8, the version `zenohex` 0.8 pins. The Elixir side speaks the rmw_zenoh protocol directly and links nothing from ROS.

## Known limitations

- Synthetic maps and actuator dynamics do not validate stereo matching, SLAM drift or physical braking.
- Nothing arbitrates between `/cmd_vel` and `/cmd_vel_nav`. Run teleop or Nav2, not both.
- The verifiers wait with fixed `sleep`s; a slow machine can fail one without anything being wrong.

## Next steps

- [ROS 2 and the simulator](../../../docs/ros2_simulator.md): how the simulator, the ROS bridge and the VMS fit together.
- [Perception: object detection](../../../docs/ros2_perception.md): the stereo and detection pipeline the perception verifier exercises.
- [Quickstart](../../../docs/quickstart.md): boot a reference vehicle on your laptop with virtual CAN.
