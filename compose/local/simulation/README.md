---
title: Simulation
description: Run your vehicle's VMS, ROS bridge, vision unit and Nav2 against a Gazebo model of it, over virtual CAN.
---

The simulator is a Gazebo **Jetty** container stack that simulates a vehicle from its model, driven by the vehicle's own VMS. The VMS runs on your machine as it does in `./ovcs run`, over virtual CAN. Simulated hardware in the vehicle's ROS bridge answers for the hardware the VMS commands, and moves the Gazebo model. Nav2, the gamepad, the stereo pipeline and the odometry all take the paths they take on the vehicle. You need no Nerves toolchain, no CAN hardware and no physical vehicle.

The OVCS Mini reference vehicle (a Traxxas Slash 4x4, 1/10 scale) has a model and simulated hardware, so the commands below use it. They work the same on your vehicle once it has both (see [Your vehicle in the simulator](#your-vehicle-in-the-simulator)).

> [!NOTE]
> The simulator stack and the simulated hardware are framework tooling. They know nothing about a vehicle beyond the files and configuration in its package, `vehicles/<vehicle>/`. See [Framework and vehicles](../../../docs/framework.md).

## What it is

The simulator speaks Zenoh like everything else. A simulated vehicle therefore appears on the same fabric as a real one, and `ros2 topic`, Foxglove and the rest need no special case. It lives in `compose/local/` beside the operator's stack because, like it, it never runs on the car.

```text
compose/local/
  simulation.yml          the stack: gazebo, gazebo-gui, nav2
  images/gazebo/          the Gazebo Jetty image
  simulation/             worlds, shared macros, gazebo.launch.py

vehicles/<vehicle>/
  description/            the URDF/xacro model and simulation.yaml, mounted into the container
  nav2/                   Nav2's parameters and behaviour trees, mounted into the nav2 service
  lib/                    the ROS bridge's simulated hardware, in ros_bridge_config/1
```

```text
Nav2 ── /cmd_vel_nav ──► Consumers.Velocity ── 0x2B1 ──► VMS ── 0x60B ──► Publishers.Odometry ── /odom, /tf ──► Nav2
                                                         │ ▲                      ▲
                                      actuator commands  │ │ status frames        │ /imu_raw (heading)
                                                         ▼ │                      │
                                                 simulated hardware               │
                                                         │ ▲                      │
                                       /simulator/drive  │ │ /joint_states        │
                                                         ▼ │                      │
                                                      Gazebo ─────────────────────┘
```

The stack simulates the vehicle named by `OVCS_VEHICLE` in `compose/local/.env`. [Command paths](../../../docs/ros2/commands.md#the-vms-drives-the-simulator) has the loop in full.

## What the simulator starts

`compose/local/simulation/launch/gazebo.launch.py` brings up one vehicle in one world, in this order:

1. `robot_state_publisher` expands the xacro and publishes `/robot_description`.
2. `gz sim -s -r` loads the world, server-only, running.
3. A `parameter_bridge` bridges `/clock`, `/joint_states`, the ground truth on `/simulator/odom`, the sensor topics the vehicle's `description/simulation.yaml` lists, and the drive command, `/simulator/drive`.
4. One `image_bridge` per camera (compressed).
5. `ros_gz_sim create` spawns the model from `/robot_description`. The model exists only now, so it comes last.

Nothing in it commands the vehicle: the VMS does ([Command paths](../../../docs/ros2/commands.md#the-vms-drives-the-simulator)).

Details that look like bugs:

- **`-s` is server-only.** The GUI is a separate service (`--profile gui`), because in a headless container Qt calls `qFatal` and the physics stop with it.
- **`-r` runs the world.** Without it the simulation loads paused, which looks exactly like a broken drive plugin.
- **Cameras go through `image_bridge`**, for bandwidth ([Running the vision unit against it](#running-the-vision-unit-against-it)).
- **`use_sim_time: true`** on every node ([Time](../../../docs/ros2/README.md#time)).
- **`GZ_IP=127.0.0.1`** on the `gazebo` and `gazebo-gui` services. They share the host's network, which has several interfaces. Without it, gz-transport discovery leaves some subscriptions unconnected. On about one start in two, a bridged topic (`/clock`, `/simulator/odom`, `/imu_raw`) never reached ROS, for every subscriber, until another Gazebo subscriber to it appeared. [gz-transport#225](https://github.com/gazebosim/gz-transport/issues/225) has the same symptom. Pinned, ten starts out of ten delivered every topic.
- **`workshop.sdf` steps every 5 ms** (`empty.sdf` every 1 ms). Gazebo publishes `/clock` once per step, so the step is also the clock's rate, which every node with `use_sim_time` receives.
- **Set `JointStatePublisher`'s rate** (50 Hz on the OVCS Mini reference vehicle). Unset, it publishes every step, and `robot_state_publisher` republishes each one on `/tf`.

The model lives with its vehicle, in `vehicles/<vehicle>/description/`, beside the `simulation.yaml` that names its sensors. It is mounted into the container rather than baked in. `OVCS_VEHICLE` in `compose/local/.env` picks the vehicle. The OVCS Mini reference vehicle's model is the worked example ([Your vehicle in the simulator](#your-vehicle-in-the-simulator)).

## Quickstart

The first run pulls and builds images: allow a few minutes. Allow over ten more the first time Nav2 starts, while its image compiles the Smac planners from source.

From the repository root, on the OVCS Mini reference vehicle (the same on yours):

```sh
cd compose/local
cp .env.example .env                            # then set OVCS_VEHICLE=ovcs_mini, ZENOH_ENDPOINT_IP=127.0.0.1

# A Zenoh router, if there is no vehicle on the LAN to peer with.
docker compose -f base.yml --profile standalone up -d zenohd

docker compose -f simulation.yml up -d          # the simulator, headless
docker compose -f simulation.yml logs -f gazebo # ^C once it has spawned the model
cd ../..

OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 ./ovcs run ovcs_mini
```

`OVCS_SIM=1` gives every role its simulated wiring: the ROS bridge runs the simulated hardware and reads the simulated IMU, and the vision unit reads the simulated cameras. Within seconds of the VMS appearing, the simulated radio's scripted switches take it through `:radio` to `:ros` with the `autonomous` commander. Set `OVCS_SIMULATOR_COMMANDER=teleop` for the gamepad instead. Then:

```sh
cd compose/local && docker compose -f simulation.yml --profile nav2 up -d nav2
docker compose -f base.yml --profile standalone up -d foxglove_bridge
```

Open Foxglove against `ws://localhost:8765`, with a layout from your vehicle's `foxglove/` directory. Send Nav2 a goal in the `odom` frame, from Foxglove or with `ros2 action send_goal`. `candump vcan1` shows the VESC commands the goal becomes.

To see the simulation, start the GUI, a separate service:

```sh
xhost +local:docker
docker compose -f simulation.yml --profile gui up -d gazebo-gui
```

Tear down with `docker compose -f simulation.yml --profile nav2 --profile gui down`, plus `docker compose -f base.yml rm -sf zenohd foxglove_bridge`.

> [!TIP]
> If the VMS dashboard shows a `FAILURE` status, the VMS finished booting before the simulated controller answered; its `reset_status` action clears it. On the vehicle the same happens when a controller boots late.

> [!TIP]
> If `ros2 topic echo` fails with `ResponseError: unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'` (a `ros2cli` daemon bug on Python 3.14), pass `--no-daemon`: `ros2 topic echo --no-daemon /odom`.

## Driving with a gamepad

The operator's `joy` service drives the simulated vehicle the way it drives the real one, over `/joy/<profile>` and the bridge's joystick path onto `0x2B0`:

```sh
cd compose/local && docker compose -f base.yml up -d joy
```

The VMS takes the gamepad only with the `teleop` commander selected: run with `OVCS_SIMULATOR_COMMANDER=teleop`.

## Odometry and ground truth

`/odom` and `odom → base_link` are the ROS bridge's, from the VMS's `0x60B` (the wheel distance) and the IMU heading, as on the vehicle.

The wheel distance is the simulated wheels'. The simulated hardware reports how far the wheel joints on `/joint_states` turned, as the vehicle's motor and shaft sensors measure the wheels. So a wheel spinning in place reads as moving, and one the model's effort limit stalls against an obstacle reads as stopped.

Ground truth is on `/simulator/odom`: the model's pose from the physics, which nothing navigates by. Compare `/odom` with it from a common start to see the dead reckoning drift. The steering system's own odometry follows the wheels rather than the body and is not bridged. See [Ground truth](../../../docs/ros2/commands.md#ground-truth).

## Running the vision unit against it

The vision unit (`vision/core`) runs unchanged against the simulator. `./ovcs run` with `OVCS_SIM=1` already starts it. Only the camera driver differs:

```text
Gazebo cameras ─► image_bridge ─/stereo/{left,right}/image_raw/compressed─► VisionCore.Ros2.Camera
  ─► VisionCore.Stereo.Supervisor ─► stereo stages ─► VisionCore.Ros2.Exporter ─► fabric
```

`VisionCore.Ros2.Camera` subscribes to a `CompressedImage` topic and hands its frames on as a physical driver does. Swapping it in for `VisionCore.Camera.LibCamera` is the entire difference between the car and the simulated car. In the OVCS Mini, `OVCS_SIM=1` (or `true`) selects it, with the simulator's clock (`OvcsMini.Vision.Composer`). No detector runs there: the vision unit detects on a Hailo-8, which a workstation does not have.

- **Compressed, not raw.** A 480×270 rgb8 frame is 389 KB; at 30 Hz, 11.6 MB/s. Over Zenoh, a subscriber that cannot drain that receives one frame every fifteen seconds, which looks like a dead topic. JPEG is about 6.5 KB a frame. Compression belongs upstream of the fabric, as on the vehicle.
- **One topic name, two roles.** The ROS 2 exporter publishes raw images on `<topic_prefix>/<side>/image_raw/compressed`, the names it consumes from `image_bridge`, so the simulated wiring turns `publish_raw_images` off.

To run it on its own:

```sh
cd vision/firmware
VEHICLE=OvcsMini OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 iex -S mix
```

`OVCS_SIM=1` selects the simulated wiring, so it cannot be picked up by accident on the vehicle. Without it, the Mini's vision unit runs no cameras on a workstation.

Two things produce **no disparity at all**:

- **An untextured world.** The matcher correlates local patches; a flat plane under a blank sky gives it nothing. Use `workshop.sdf`, the default, for anything involving depth.
- **The vehicle's own calibration.** Gazebo renders an ideal pinhole, and real distortion coefficients and rectification rotations warp the views apart. The simulator's calibration, `vehicles/ovcs_mini/priv/calibration/simulation/`, has D = 0 and R = I, with the real focal length scaled to the capture resolution. The optics match the vehicle; the distortion model matches the simulator.

## Navigating with Nav2

```sh
docker compose -f simulation.yml --profile nav2 up -d --build nav2
docker logs -f ovcs-nav2
```

This is Nav2 from the Lyrical apt archive (1.5.1 when written), in the **vehicle's own image** (`compose/compute/images/nav2/`, tagged `ovcs/nav2:lyrical`). The vehicle's parameters and behaviour trees (`vehicles/<vehicle>/nav2/`) are mounted in. Nav2 sits behind a profile, so a plain `up -d` stays a bare simulator. The one difference is the clock, a visible launch argument (`use_sim_time:=true`). There is no map and no AMCL: every frame is `odom` and both costmaps roll with the vehicle.

The controller and behaviours publish `/cmd_vel_nav_raw`; `velocity_smoother` republishes it on `/cmd_vel_nav`, which the ROS bridge carries to the VMS as on the vehicle.

[Nav2, as configured here](../../../docs/ros2/README.md#nav2-as-configured-here) explains why the configuration is as it is, and the traps it avoids.

## Your vehicle in the simulator

The simulator reads three things from `vehicles/<vehicle>/`:

| File | Contents |
|---|---|
| `description/<vehicle>.urdf.xacro` | the model, with Gazebo's `AckermannSteering` system taking its drive command, an `OdometryPublisher` system publishing ground truth on `/simulator/odom`, and its sensors' Gazebo plugins. Shared macros are at `../../common` relative to it, inside the container. Meshes are named under the `mesh_uri` xacro argument, which the framework sets to `package://ovcs_description/meshes`: Gazebo and `foxglove_bridge` resolve that package to the vehicle's `description/`. |
| `description/simulation.yaml` | under `gazebo`: the sensor topics to bridge to ROS, the cameras, the spawn height. |
| `nav2/` | `nav2.yaml` and the behaviour trees it references under `/opt/ovcs/config/`. |

The `ros` bridge also needs a simulated component for each piece of hardware the VMS drives, wired into its host configuration and CAN topology. [Simulate a component](../../../docs/simulator/simulate_a_component.md) writes one and wires it in.

The OVCS Mini reference vehicle's model is the worked example. [`vehicles/ovcs_mini/description/`](../../../vehicles/ovcs_mini/description/README.md) documents its dimensions and which of them are estimates. `inertial_macros.xacro` comes from the earlier [traxxas](https://github.com/open-vehicle-control-system/traxxas) model, which targeted Gazebo Classic. A centre of gravity at half the body height rolls a model over in its first corner. The Mini carries its chassis mass in a low tub for that reason.

## Why Jetty, and why Lyrical

ROS 2 Jazzy supports only Gazebo Harmonic. Jetty, the current LTS, needs ROS 2 **Lyrical**, so the whole ROS stack is on Lyrical. Both sides run zenoh 1.8, the version `zenohex` 0.8 pins. The Elixir side speaks the rmw_zenoh protocol directly and links nothing from ROS.

## Known limitations

- **Gazebo can run slower than real time**, without a GPU or on a loaded machine. Nav2 follows its clock, so goals take longer in wall time. The VMS's watchdogs stay on the wall clock, and `/odom`'s twist is per wall second.
- **Gazebo needs the GPU.** The `gazebo` and `gazebo-gui` services mount `/dev/dri`. Without a GPU there, Mesa renders the cameras on the CPU (`llvmpipe`). Measured on an Intel Iris Xe, that is about 1040 % of CPU against 130 % with the GPU. The contention is enough for the simulated controller's frames to arrive later than the VMS's frame watchers allow, which shows as a VMS `FAILURE`. An NVIDIA GPU needs the NVIDIA Container Toolkit as well.
- **The Smac planners are built from source** in the Nav2 image: they are released for Lyrical but absent from its archive. Bumping the image's ROS snapshot means bumping `SMAC_RELEASE` with it.
- `yaw_goal_tolerance` is deliberately about π. A car cannot rotate to a commanded final heading.

## Next steps

- [ROS 2](../../../docs/ros2/README.md): how the simulator, the ROS bridge and the VMS fit together.
- [Vision unit](../../../docs/vision/README.md): the stereo and detection pipeline.
- [Quickstart](../../../docs/quickstart.md): boot a reference vehicle on your laptop with virtual CAN.
