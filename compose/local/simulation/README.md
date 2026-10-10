---
title: Simulation
description: Drive a vehicle in Gazebo with nothing but Docker, then point the real perception pipeline and Nav2 at it.
---

A Gazebo **Jetty** container stack that simulates a vehicle from its model. It needs Docker and Compose v2 and nothing else: no Nerves toolchain, no CAN interface, no physical vehicle. It is the quickest way to see OVCS do something. The OVCS Mini reference vehicle (a Traxxas Slash 4x4, 1/10 scale) has a model, so the commands below use it; they work the same on your vehicle once it has [its own](#your-vehicle-in-the-simulator).

> [!NOTE]
> The simulator stack is framework tooling. It knows nothing about a vehicle beyond the files mounted from its package, `vehicles/<vehicle>/`. See [Framework and vehicles](../../../docs/framework.md).

> [!WARNING]
> The gamepad and Nav2 drive Gazebo's physics **directly**. The VMS and the CAN bus are **not in that loop**; the Elixir bridge runs against the simulator only for perception (and, on the host ROS bridge, the IMU). A CAN frame is not what moves the simulated car. [ROS 2 and the simulator](../../../docs/ros2_simulator.md#commands-three-paths-and-a-gap) shows both loops.

## What it is

The simulator speaks Zenoh like everything else, so a simulated vehicle appears on the same fabric as a real one, and `ros2 topic`, Foxglove and the rest need no special case. It lives in `compose/local/` beside the operator's stack because, like it, it never runs on the car.

```text
compose/local/
  simulation.yml          the stack: sim, teleop, gz-gui, nav2
  images/sim/             the Gazebo Jetty image
  simulation/             worlds, shared macros, sim.launch.py, gamepad mapping

vehicles/<vehicle>/
  description/            the URDF/xacro model and simulation.yaml, mounted into the container
  nav2/                   Nav2's parameters and behaviour trees, mounted into the nav2 service
```

The stack simulates the vehicle named by `OVCS_VEHICLE` in `compose/local/.env`.

## Quickstart

Every command runs from `compose/local/`. The stacks are named files, so `-f` is always spelled out. The first run pulls and builds images; budget a few minutes.

```sh
cd compose/local
cp .env.example .env                            # OVCS_VEHICLE=ovcs_mini, or your vehicle

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

## Driving with a gamepad

```sh
docker compose -f simulation.yml --profile teleop up -d teleop   # needs a joystick at /dev/input/js0
```

Nothing arbitrates `/cmd_vel`: stop a `topic pub` left running before using the gamepad. Nav2 has its own ROS topic, `/cmd_vel_nav`, but both bridges drive the same Gazebo command topic, so a leftover `/cmd_vel` publisher disturbs Nav2 as well.

`/odom` is a command echo. Gazebo's `AckermannSteering` divides the commanded speed by the model's wheel radius to get a joint velocity, then multiplies by it again for odometry, so a wrong radius never shows in `/odom`. The physical speed is `/joint_states`' wheel velocity times the vehicle's real radius.

## Running the perception bridge against it

The stereo stack (SGBM, rectification, publishers, detector) is framework code in `bridges/ros_bridge` and runs unchanged against the simulator. The OVCS Mini reference vehicle wires it in its `ros_bridge_config/2`; `VEHICLE=OvcsMini` below selects that vehicle, and yours is selected the same way. Only the camera driver differs: `RosBridge.Camera.Zenoh` subscribes to a ROS image topic and emits the same frames a physical driver does.

```sh
./ovcs can setup ovcs_mini          # once; Cantastic needs vcan0 to exist (same on your vehicle)

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
docker compose -f simulation.yml --profile nav2 up -d --build nav2
docker logs -f ovcs-nav2
```

This is Nav2 from the Lyrical apt archive (1.5.1 when written) in the **vehicle's own image** (`compose/compute/images/nav2/`, tagged `ovcs/nav2:lyrical`), with the vehicle's parameters and behaviour trees (`vehicles/<vehicle>/nav2/`) mounted in, behind a profile so a plain `up -d` stays a bare simulator. The one difference is the clock, a visible launch argument (`use_sim_time:=true`). No map and no AMCL: every frame is `odom` and both costmaps roll with the vehicle.

The controller and behaviours publish `/cmd_vel_nav_raw`; `velocity_smoother` republishes it on `/cmd_vel_nav` with a deadband that sends any linear velocity under the vehicle's slowest drivable speed as zero: 0.08 m/s on the OVCS Mini reference vehicle, its VESC floor ([VESC drivetrain](../../../docs/vesc_drivetrain.md)). Gazebo would drive slower; the deadband is there to run the vehicle's configuration.

### Four things that fail silently

- **Nav2 publishes `TwistStamped`.** `nav2_util::TwistPublisher` defaults `enable_stamped_cmd_vel` to true, whatever its header comment says. The `/cmd_vel` bridge is unstamped, so Nav2 has its own topic (`/cmd_vel_nav`) and its own bridge node onto the same Gazebo topic. Without it, a healthy-looking Nav2 moves nothing.
- **`motion_model` names a plugin instance, not a class.** The class comes from `<instance>.plugin`; naming the class directly fails with "No 'plugin' param for param ns!". Leaving `motion_model` unset fails loudly: MPPI defaults it to `diff_drive`, which has no `.plugin`, so the controller refuses to configure.
- **The odometry frame needs `<frame_id>`.** Without it `AckermannSteering` namespaces the frame by model name (`<vehicle>/odom`), Nav2 rejects it, and every costmap logs `Invalid frame ID "odom"` and never activates. The OVCS Mini reference vehicle's `gazebo_ackermann.xacro` sets `odom` / `base_link`, at 50 Hz.
- **`Spin` aborts navigation on a car.** Both stock behaviour trees put it in their recovery branch; an Ackermann vehicle produces no motion from a spin, so it runs its full duration and burns a recovery slot. Both trees drop it. The spin *server* stays loaded because `bt_navigator` resolves every action at activation.

### Arriving proves almost nothing

`AckermannSteering` quietly ignores commands it cannot execute, so a controller configured for a differential-drive robot still arrives while commanding arcs the steering could never cut: with `mppi::DiffDriveMotionModel` substituted in, the vehicle reached a tight goal *better* than the correct configuration while commanding a yaw rate 3.68× the kinematic limit. Judge a configuration by what it commands on `/cmd_vel_nav_raw` (`|wz| <= |vx| / min_turning_r`), not by whether it arrives.

## Your vehicle in the simulator

The simulator reads three things from `vehicles/<vehicle>/`:

| File | Contents |
|---|---|
| `description/<vehicle>.urdf.xacro` | the model, with Gazebo's `AckermannSteering` system publishing `odom` / `base_link` and its sensors' Gazebo plugins. Shared macros are at `../../common` relative to it, inside the container. |
| `description/simulation.yaml` | under `gazebo`: the sensor topics to bridge to ROS, the cameras, the spawn height. |
| `nav2/` | `nav2.yaml` and the behaviour trees it references under `/opt/ovcs/config/`. |

The OVCS Mini reference vehicle's are the worked example: [`vehicles/ovcs_mini/description/`](../../../vehicles/ovcs_mini/description/README.md) documents its dimensions and which of them are estimates, and `inertial_macros.xacro` and the gamepad mapping in `config/` come from the earlier [traxxas](https://github.com/open-vehicle-control-system/traxxas) model, which targeted Gazebo Classic. A centre of gravity at half the body height rolls a model over in its first corner; the Mini carries its chassis mass in a low tub for that reason.

## Why Jetty, and why Lyrical

ROS 2 Jazzy supports only Gazebo Harmonic; Jetty, the current LTS, needs ROS 2 **Lyrical**, so the whole ROS stack is on Lyrical. The move changed nothing on the wire: all 14 `RIHS01_` type hashes `ros_bridge` carried over from Jazzy are identical on Lyrical (the 15th, `nav_msgs/msg/Odometry`, was captured on Lyrical directly), and both sides run zenoh 1.8, the version `zenohex` 0.8 pins. The Elixir side speaks the rmw_zenoh protocol directly and links nothing from ROS.

## Known limitations

- Global plans come from NavFn (`nav2_smac_planner` is absent from the Lyrical archive), so they are **not kinematically feasible**: MPPI carries the corners the car cannot cut. Fine in an open workshop, a real constraint in tight spaces.
- `yaw_goal_tolerance` is deliberately about π. A car cannot rotate to a commanded final heading.
- Nothing arbitrates between `/cmd_vel` and `/cmd_vel_nav`. Run teleop or Nav2, not both.

## Next steps

- [ROS 2 and the simulator](../../../docs/ros2_simulator.md): how the simulator, the ROS bridge and the VMS fit together.
- [Perception: object detection](../../../docs/ros2_perception.md): the stereo and detection pipeline.
- [Quickstart](../../../docs/quickstart.md): boot a reference vehicle on your laptop with virtual CAN.
