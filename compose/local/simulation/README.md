---
title: Simulation
description: Run your vehicle's VMS, ROS bridge, perception and Nav2 against a Gazebo model of it, over virtual CAN.
---

A Gazebo **Jetty** container stack that simulates a vehicle from its model, driven by the vehicle's own VMS. The VMS runs on your machine as it does in `./ovcs run`, over virtual CAN, and simulated hardware in the vehicle's ROS bridge answers for the hardware it commands and moves the Gazebo model. Nav2, the gamepad, the stereo pipeline and the odometry all take the paths they take on the vehicle. No Nerves toolchain, no CAN hardware and no physical vehicle are needed. The OVCS Mini reference vehicle (a Traxxas Slash 4x4, 1/10 scale) has a model and simulated hardware, so the commands below use it; they work the same on your vehicle once it has [both](#your-vehicle-in-the-simulator).

> [!NOTE]
> The simulator stack and the simulated hardware are framework tooling. They know nothing about a vehicle beyond the files and configuration in its package, `vehicles/<vehicle>/`. See [Framework and vehicles](../../../docs/framework.md).

## What it is

The simulator speaks Zenoh like everything else, so a simulated vehicle appears on the same fabric as a real one, and `ros2 topic`, Foxglove and the rest need no special case. It lives in `compose/local/` beside the operator's stack because, like it, it never runs on the car.

```text
compose/local/
  simulation.yml          the stack: gazebo, gazebo-gui, nav2
  images/gazebo/          the Gazebo Jetty image
  simulation/             worlds, shared macros, gazebo.launch.py

vehicles/<vehicle>/
  description/            the URDF/xacro model and simulation.yaml, mounted into the container
  nav2/                   Nav2's parameters and behaviour trees, mounted into the nav2 service
  lib/                    the ROS bridge's simulated hardware, in ros_bridge_config/2
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

The stack simulates the vehicle named by `OVCS_VEHICLE` in `compose/local/.env`. [ROS 2 and the simulator](../../../docs/ros2_simulator.md#the-vms-drives-the-simulator) has the loop in full.

## Quickstart

The first run pulls and builds images; budget a few minutes, and over ten more the first time Nav2 starts, while its image compiles the Smac planners from source. From the repository root, on the OVCS Mini reference vehicle (the same on yours):

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

`OVCS_SIM=1` gives every bridge its simulated wiring: the ROS bridge runs the simulated hardware and reads the simulated IMU, and its perception components read the simulated cameras. Within seconds of the VMS appearing, the simulated radio's scripted switches take it through `:radio` to `:ros` with the `autonomous` commander (`OVCS_SIMULATOR_COMMANDER=teleop` for the gamepad instead). Then:

```sh
cd compose/local && docker compose -f simulation.yml --profile nav2 up -d nav2
docker compose -f base.yml --profile standalone up -d foxglove_bridge
```

Open Foxglove against `ws://localhost:8765`, with a layout from your vehicle's `foxglove/` directory, and send Nav2 a goal from it or with `ros2 action send_goal`, in the `odom` frame. `candump vcan1` shows the VESC commands it becomes.

See it. The GUI is a separate service, because Qt in a headless container takes the physics down with it:

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

`/odom` and `odom → base_link` are the ROS bridge's, from the VMS's `0x60B` (the wheel distance) and the IMU heading, as on the vehicle. The wheel distance is the simulated wheels': the simulated hardware reports how far the wheel joints on `/joint_states` turned, as the vehicle's motor and shaft sensors measure the wheels, so a wheel spinning in place reads as moving, and one the model's effort limit stalls against an obstacle reads as stopped. `/simulator/odom` is ground truth, the model's pose from the physics, which nothing navigates by: compare the two from a common start to see the dead reckoning drift. The steering system's own odometry follows the wheels rather than the body and is not bridged. See [Ground truth](../../../docs/ros2_simulator.md#ground-truth).

## Running perception against it

The stereo stack (SGBM, rectification, publishers, detector) is framework code in `bridges/ros_bridge` and runs unchanged against the simulator; `./ovcs run` with `OVCS_SIM=1` already starts it. Only the camera driver differs: `RosBridge.Camera.Zenoh` subscribes to a ROS image topic and emits the same frames a physical driver does. To run it on its own:

```sh
./ovcs can setup ovcs_mini          # once; Cantastic needs vcan0 to exist (same on your vehicle)

cd bridges/firmware
VEHICLE=OvcsMini OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_vision CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  iex -S mix
```

Three details fail misleadingly if wrong:

- **Start from `bridges/firmware`, not `bridges/ros_bridge`.** The library has no `config/`, so `CAN_NETWORK_MAPPINGS` is never read there and Cantastic dies with "CAN network mappings are missing from the Cantastic configuratiion". The firmware project is what `./ovcs run` starts; its `config/runtime.exs` consumes the variable.
- **`BRIDGE_FIRMWARE_ID=ros_vision` is required.** On the host it otherwise defaults to `radio_control`, so no ROS bridge starts at all.
- **`OVCS_SIM=1` selects the simulated wiring**, so it cannot be picked up by accident on the vehicle. No Hailo detector there, since a workstation has no accelerator; `OVCS_DETECTOR` picks a backend instead ([Perception: object detection](../../../docs/ros2_perception.md)).

Measured against `workshop.sdf`: 30.3 Hz, 61.2 % depth coverage, median depth 0.81 m and p75 1.75 m, on the world's two boxes.

Two things produce **no disparity at all**:

- **An untextured world.** SGBM correlates local patches; a flat plane under a blank sky gives it nothing. Use `workshop.sdf`, the default, for anything involving depth.
- **The vehicle's own calibration.** Gazebo renders an ideal pinhole, and real distortion coefficients and rectification rotations warp the views apart: 5.4 % coverage. The simulator's calibration, `vehicles/ovcs_mini/priv/calibration/simulation/`, has D = 0 and R = I, with the real focal length scaled to the capture resolution: the optics match the vehicle, the distortion model matches the simulator.

## Navigating with Nav2

```sh
docker compose -f simulation.yml --profile nav2 up -d --build nav2
docker logs -f ovcs-nav2
```

This is Nav2 from the Lyrical apt archive (1.5.1 when written) in the **vehicle's own image** (`compose/compute/images/nav2/`, tagged `ovcs/nav2:lyrical`), with the vehicle's parameters and behaviour trees (`vehicles/<vehicle>/nav2/`) mounted in, behind a profile so a plain `up -d` stays a bare simulator. The one difference is the clock, a visible launch argument (`use_sim_time:=true`). No map and no AMCL: every frame is `odom` and both costmaps roll with the vehicle.

The controller and behaviours publish `/cmd_vel_nav_raw`; `velocity_smoother` republishes it on `/cmd_vel_nav`, which the ROS bridge carries to the VMS as on the vehicle.

Why the configuration is as it is, and the traps it avoids, are in [Nav2, as configured here](../../../docs/ros2_simulator.md#nav2-as-configured-here).

## Your vehicle in the simulator

The simulator reads three things from `vehicles/<vehicle>/`:

| File | Contents |
|---|---|
| `description/<vehicle>.urdf.xacro` | the model, with Gazebo's `AckermannSteering` system taking its drive command, an `OdometryPublisher` system publishing ground truth on `/simulator/odom`, and its sensors' Gazebo plugins. Shared macros are at `../../common` relative to it, inside the container. Meshes are named under the `mesh_uri` xacro argument, which the framework sets to `package://ovcs_description/meshes`: Gazebo and `foxglove_bridge` resolve that package to the vehicle's `description/`. |
| `description/simulation.yaml` | under `gazebo`: the sensor topics to bridge to ROS, the cameras, the spawn height. |
| `nav2/` | `nav2.yaml` and the behaviour trees it references under `/opt/ovcs/config/`. |

The ROS bridge needs two more things from the vehicle package: a `:simulated_hardware` in its host `ros_bridge_config/2` against the simulator, listing a `RosBridge.Simulator.SimulatedComponent` for each piece of hardware the VMS drives, and their frames in its host CAN topology, through a `%{host: _, target: _}` `can_config_path` (see `OvcsVehicle`). The OVCS Mini's `ros_bridge_simulation_config/0` and `priv/can/bridges/ros_simulated_components.yml` are the worked example; hardware with no simulated component yet, such as the OVCS1 reference vehicle's inverter or brake booster, needs one written first.

The OVCS Mini reference vehicle's model is the worked example: [`vehicles/ovcs_mini/description/`](../../../vehicles/ovcs_mini/description/README.md) documents its dimensions and which of them are estimates, and `inertial_macros.xacro` comes from the earlier [traxxas](https://github.com/open-vehicle-control-system/traxxas) model, which targeted Gazebo Classic. A centre of gravity at half the body height rolls a model over in its first corner; the Mini carries its chassis mass in a low tub for that reason.

## Why Jetty, and why Lyrical

ROS 2 Jazzy supports only Gazebo Harmonic; Jetty, the current LTS, needs ROS 2 **Lyrical**, so the whole ROS stack is on Lyrical. The move changed nothing on the wire: every `RIHS01_` type hash `ros_bridge` carried over from Jazzy is identical on Lyrical, and both sides run zenoh 1.8, the version `zenohex` 0.8 pins. The Elixir side speaks the rmw_zenoh protocol directly and links nothing from ROS.

## Known limitations

- **Gazebo can run slower than real time**, without a GPU or on a loaded machine. Nav2 follows its clock, so goals take longer in wall time; the VMS's watchdogs stay on the wall clock, and `/odom`'s twist is per wall second.
- **Gazebo needs the GPU.** The `gazebo` and `gazebo-gui` services mount `/dev/dri`; without a GPU there, Mesa renders the cameras on the CPU (`llvmpipe`). Measured on an Intel Iris Xe, that is about 1040 % of CPU against 130 % with the GPU, and enough contention for the simulated controller's frames to arrive later than the VMS's frame watchers allow, which shows as a VMS `FAILURE`. An NVIDIA GPU needs the NVIDIA Container Toolkit as well.
- **The Smac planners are built from source** in the Nav2 image: they are released for Lyrical but absent from its archive. Bumping the image's ROS snapshot means bumping `SMAC_RELEASE` with it.
- `yaw_goal_tolerance` is deliberately about π. A car cannot rotate to a commanded final heading.

## Next steps

- [ROS 2 and the simulator](../../../docs/ros2_simulator.md): how the simulator, the ROS bridge and the VMS fit together.
- [Perception: object detection](../../../docs/ros2_perception.md): the stereo and detection pipeline.
- [Quickstart](../../../docs/quickstart.md): boot a reference vehicle on your laptop with virtual CAN.
