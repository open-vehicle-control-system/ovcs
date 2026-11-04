---
title: ROS bridge
description: The bridge between the ovcs CAN bus and ROS 2 over native Zenoh, the components a vehicle opts into, how to configure it on the host and the target, tune its stereo cameras at runtime, and check it end to end.
---

The ROS bridge, `RosBridge`, connects your vehicle to a ROS 2 graph. It speaks the [`rmw_zenoh`](https://github.com/ros2/rmw_zenoh) wire format natively over [Zenoh](https://zenoh.io), through [`zenohex`](https://hex.pm/packages/zenohex), and links nothing from ROS: the bridge's board runs Nerves like every other role, and ROS nodes, `ros2 topic echo` and Foxglove see its topics as native. Commands come in from ROS and go out as CAN frames to the VMS; what the vehicle knows goes out as ROS topics.

> [!NOTE]
> The OVCS1 and OVCS Mini reference vehicles both run it; the OVCS Mini is the worked example. See [Framework and vehicles](../framework.md). How the bridge fits with the compute node, the simulator and Nav2 is in [ROS 2](../ros2/README.md).

## How it works

```text
ROS 2 graph ── Zenoh router ── RosBridge.ZenohClient
                                   │
              consumers  <─────────┤─────────>  publishers
   /joy/<profile>, cmd_vel         │      /vehicle/*, /imu, /odom, /scan, /stereo/*, /tf_static
              │                    │                    ^
              v                    │                    │
   ovcs bus: 0x2B0, 0x2B1          │    ovcs bus: 0x1A0, 0x600, 0x60B, 0x60C; drivers on the board
```

- **One Zenoh session.** `RosBridge.ZenohClient` holds a client session with the vehicle's Zenoh router on `tcp/<zenoh_endpoint_ip>:7447`, reconnects with a backoff from 1 s to 30 s, and gives the rest of the bridge `publish` and `subscribe`. The router runs on the [compute node](../ros2/compute_node.md) on a vehicle, or in the local ROS 2 stack on a workstation.
- **Consumers turn ROS commands into CAN.** `RosBridge.Consumers.Joy` turns a gamepad's `sensor_msgs/Joy`, read through a joystick profile, into the actuator command (`0x2B0`). `RosBridge.Consumers.Velocity` turns a planner's `geometry_msgs/TwistStamped` into the velocity command (`0x2B1`), and the VMS solves the kinematics against its own geometry. Both carry a sequence number; when it stops changing, the VMS zeroes the command.
- **Publishers turn what the vehicle knows into topics.** Some read CAN frames the VMS emits (status, gear, control level, vehicle motion); others own a driver on the bridge's board (an IMU, a lidar, rangefinders, stereo cameras).
- **Supervision.** The session, the node's parameter server and the components run under one `rest_for_one` supervisor, so a restarted Zenoh session restarts every component after it.

The message codecs and the `rmw_zenoh` key expressions come from [`ros2_zenoh`](../../libraries/ros2_zenoh/README.md), which also explains how to add a message type.

## Components

Apart from the Zenoh session, every feature is a component your vehicle opts into. The [`RosBridge.Components`](../../bridges/ros_bridge/lib/ros_bridge/components.ex) moduledoc is the reference for each one's options.

| Component | What it does |
|---|---|
| `:heartbeat` | `std_msgs/String` on `/ovcs_heartbeat`, every second by default, so consumers see the bridge is alive |
| `:joy_interpreter` | a gamepad's `/joy/<profile>` onto `0x2B0`, through the framework's joystick profiles in `priv/joy` plus your vehicle's own |
| `:velocity_interpreter` | a velocity command (`cmd_vel` by default) onto `0x2B1` |
| `:vehicle_status_publisher` | the VMS's status, gear and control level on `/vehicle/*`, from `0x1A0`, `0x600` and `0x60C` |
| `:imu_publisher` | starts an `OvcsDrivers.Imu` driver (`OvcsDrivers.Imu.Dummy` on the host, the BNO085 on the target) and publishes `sensor_msgs/Imu` |
| `:odometry_publisher` | dead-reckoned `/odom` and the `odom → base_link` transform, from the VMS's `vehicle_motion` frame (`0x60B`) and the IMU heading; list `:imu_publisher` first |
| `:ackermann_joint_states` | an Ackermann vehicle's wheels on `/joint_states` from `vehicle_motion`, for `robot_state_publisher`; not against a simulator, which publishes its own |
| `:static_transforms` | the vehicle's fixed frames on `/tf_static`, so frame ids in headers resolve |
| `:lidar_publisher` | starts an `OvcsDrivers.Lidar` driver (an RPLIDAR over USB serial) and publishes `sensor_msgs/LaserScan` |
| `:range_publisher` | one rangefinder (an A02YYUW ultrasonic sensor over USB serial) as `sensor_msgs/Range`; list it once per sensor |
| `:stereo_camera` | two cameras, their images and `camera_info`, and depth from OpenCV's `StereoSGBM` through evision |
| `:hailo_detector`, `:detector` | object detection fused with the stereo depth, on a Hailo-8 or on the CPU or GPU; see [Perception](./perception.md) |
| `:simulator_clock`, `:simulated_hardware` | simulation only: follow `/clock`, and emulate the vehicle's hardware on CAN so the VMS drives a Gazebo model; see [Simulation](../../compose/local/simulation/README.md) |

The [vision unit](../vision/README.md) is the other place stereo depth runs, as a role of its own on a dedicated board, without OpenCV. A vehicle runs stereo in one or the other.

## Configure it in your vehicle

Declare the bridge in an entry of `bridge_firmwares/0` (see [Bridge firmwares](./README.md#bridge-firmwares)), then implement `ros_bridge_config/1` on your vehicle's top-level module. It returns a `%RosBridge.Config{}` per arm:

```elixir
def ros_bridge_config(:host) do
  %RosBridge.Config{
    zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
    components: [
      :heartbeat,
      :joy_interpreter,
      {:imu_publisher, driver: OvcsDrivers.Imu.Dummy}
    ]
  }
end

def ros_bridge_config(:target) do
  %RosBridge.Config{
    zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
    # Required only when more than one bridge firmware runs the ROS bridge on one Zenoh fabric.
    node_name: "ovcs_bridge_ros",
    components: [
      :heartbeat,
      :joy_interpreter,
      {:imu_publisher, driver: BNO085.I2C}
    ]
  }
end
```

A bare atom is shorthand for `{atom, []}`. An unknown component name raises at boot, so a typo fails loudly instead of silently dropping a feature.

A vehicle that bundles `RosBridge` in several `bridge_firmwares/0` entries implements `ros_bridge_config/2` instead, which also receives the bridge firmware id, so each entry gets its own components. The OVCS Mini reference vehicle's target configuration, abridged:

```elixir
defp ros_bridge_target_config,
  do: %RosBridge.Config{
    zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
    node_name: "ovcs_bridge_ros",
    components: [
      :heartbeat,
      :joy_interpreter,
      {:velocity_interpreter,
       %{topic: "cmd_vel_nav", message: Ros2Zenoh.GeometryMsgs.Msg.TwistStamped}},
      {:imu_publisher, driver: BNO085.I2C},
      {:odometry_publisher,
       driver: BNO085.I2C, base_ahead_of_rear_axle: base_ahead_of_rear_axle()}
      # … the lidar, the rear ultrasonics and their static transforms
    ]
  }
```

Order matters where one component reads another: `:odometry_publisher` comes after `:imu_publisher`, which starts the IMU driver it reads.

- **Host and target.** The arm is fixed at compile time from `Mix.target()`. The `:host` arm swaps hardware drivers for dummies so `./ovcs run <vehicle>` works without sensors, and usually points at a router on loopback.
- **The router's address.** On the target, `ZENOH_ENDPOINT_IP` at firmware build time sets `:zenoh_endpoint_ip`; your vehicle's `.env.exs` sets it to the compute node's address. Without a `.env.exs` the build fails, because the image would fall back to `127.0.0.1` and reach no router.
- **The node name.** `node_name` is what the bridge announces, the name `ros2 node list` and Foxglove show, `ovcs_bridge` by default. Two bridge firmwares on one fabric must each set their own, or they collide in the ROS graph and Foxglove renders them as one node. The OVCS Mini's is `ovcs_bridge_ros`, next to its vision unit's `ovcs_vision`.

## Tune the stereo cameras at runtime

The bridge's node serves ROS 2 parameters (`RosBridge.Parameters`), and every `:stereo_camera` unit declares its settings there (`RosBridge.StereoCamera.Parameters`), so you can change them while watching the images and the depth, from Foxglove's Parameters panel or the `ros2 param` CLI (`<node>` is the bridge's `node_name`):

```bash
ros2 param list /<node>
ros2 param describe /<node> stereo.left.lens_position
ros2 param set /<node> stereo.left.lens_position 1.2
ros2 param dump /<node>
```

| Parameters | Settings |
|---|---|
| `<prefix>.left.*`, `<prefix>.right.*` | each camera's runtime controls (`RosBridge.Camera.LibCamera.control_specs/0`): exposure mode, shutter time and gain (0 for automatic), focus, brightness, contrast, sharpness, noise reduction |
| `<prefix>.*` | the matching settings (`RosBridge.StereoCamera.OpenCV.option_specs/0`) |
| read-only | each camera's addressing, sync role, sensor mode and calibration file, and the resolution and frame rate |

Each parameter carries its type, range or accepted values and a description; a value outside them is refused with the reason.

What the cameras actually apply goes to `/diagnostics` (`RosBridge.StereoCamera.Live`): per camera the shutter time, gains, focus, frame duration, colour temperature and sync state that libcamera reports, and for the pair the time between the two cameras' frames, with a warning above 1 ms. `<prefix>/live/sync_offset_ms` and each camera's `<prefix>/live/<side>/exposure_time_us` and `analogue_gain` (`std_msgs/Float64`) carry the same values for plotting.

Changes last until the stereo unit restarts: copy the values you keep from `ros2 param dump` into your vehicle's configuration. The Foxglove layout [`ovcs_stereo_tuning.json`](../../compose/local/foxglove/ovcs_stereo_tuning.json) shows both cameras, rectified so their rows align as the matcher sees them, and the depth next to the stereo parameters as sliders, menus and toggles (the [`parameter-sliders`](../../compose/local/foxglove/extensions/parameter-sliders) panel, installed once in Foxglove), the diagnostics and plots of the sync offset, exposure and gain. It reads the OVCS Mini's vision unit, `/ovcs_vision`: set the sliders panel's node to your bridge's `node_name`, and add that node to the `param_whitelist` of `compose/compute/images/ros2/docker/foxglove_bridge.sh`.

## Check it end to end

With `./ovcs run <vehicle>` going and the local ROS 2 stack up, the bridge's `/ovcs_heartbeat` appears in `ros2 topic list` and in Foxglove. [Verifying end to end](../ros2/README.md#verifying-end-to-end) has the commands.

## Where next

- [ROS 2](../ros2/README.md): the Zenoh fabric, who publishes which topic, time, the command paths and Nav2.
- [Perception](./perception.md): object detection fused with stereo depth.
- [ROS compute node](../ros2/compute_node.md): the machine that runs the Zenoh router on the vehicle.
