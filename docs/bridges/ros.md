---
title: ROS bridge
description: The bridge between the ovcs CAN bus and ROS 2 over native Zenoh, the components a vehicle opts into, and how to configure it and check it end to end.
---

The ROS bridge, `RosBridge`, connects your vehicle to a ROS 2 graph. It speaks the [`rmw_zenoh`](https://github.com/ros2/rmw_zenoh) wire format natively over [Zenoh](https://zenoh.io), through [`zenohex`](https://hex.pm/packages/zenohex), and links nothing from ROS. The bridge's board runs Nerves like every other role. ROS nodes, `ros2 topic echo` and Foxglove see its topics as native.

Commands come in from ROS and go out as CAN frames to the VMS. What the vehicle knows goes out as ROS topics.

> [!NOTE]
> The OVCS1 and OVCS Mini reference vehicles both run it; the OVCS Mini is the worked example. See [Framework and vehicles](../framework.md). How the bridge fits with the compute node, the simulator and Nav2 is in [ROS 2](../ros2/README.md).

## How it works

```text
ROS 2 graph ── Zenoh router ── Ros2Zenoh.Client
                                   │
              consumers  <─────────┤─────────>  publishers
   /joy/<profile>, cmd_vel         │      /vehicle/*, /imu, /odom, /scan, /proximity/*, /tf_static
              │                    │                    ^
              v                    │                    │
   ovcs bus: 0x2B0, 0x2B1          │    ovcs bus: 0x1A0, 0x600, 0x60B, 0x60C; drivers on the board
```

- **One Zenoh session.** `Ros2Zenoh.Client`, from [`libraries/ros2_zenoh`](../../libraries/ros2_zenoh/README.md), holds a client session with the vehicle's Zenoh router on `tcp/<zenoh_endpoint_ip>:7447`. It reconnects with a backoff from 1 s to 30 s, and gives the rest of the bridge `publish` and `subscribe`. The router runs on the [compute node](../ros2/compute_node.md) on a vehicle, or in the local ROS 2 stack on a workstation.
- **Consumers turn ROS commands into CAN.** `RosBridge.Consumers.Joy` turns a gamepad's `sensor_msgs/Joy`, read through a joystick profile, into the actuator command (`0x2B0`). `RosBridge.Consumers.Velocity` turns a planner's `geometry_msgs/TwistStamped` into the velocity command (`0x2B1`), and the VMS solves the kinematics against its own geometry. Both carry a sequence number. When it stops changing, the VMS zeroes the command.
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
| `:path_prediction` | the arc the vehicle follows at its commanded steering angle on `/vehicle/predicted_path` (`nav_msgs/Path`), and, while it moves, where it will be in a second on `/vehicle/predicted_pose` (`geometry_msgs/PoseStamped`), from `vehicle_motion` and `gear_status` (`0x600`) |
| `:static_transforms` | the vehicle's fixed frames on `/tf_static`, so frame ids in headers resolve |
| `:lidar_publisher` | starts an `OvcsDrivers.Lidar` driver (an RPLIDAR over USB serial) and publishes `sensor_msgs/LaserScan` |
| `:proximity` | the lidar's nearest return on `/proximity/nearest` (`sensor_msgs/Range`), and the nearest return of each sector labelled with its distance on `/proximity/labels` (`visualization_msgs/MarkerArray`), from `/scan` |
| `:range_publisher` | one rangefinder (an A02YYUW ultrasonic sensor over USB serial) as `sensor_msgs/Range`; list it once per sensor. While an `:odometry_publisher` runs, readings go out only while it publishes `odom → base_link` |
| `:simulator_clock`, `:simulated_hardware` | simulation only: follow `/clock`, and emulate the vehicle's hardware on CAN so the VMS drives a Gazebo model; see [Simulation](../../compose/local/simulation/README.md) |

The [vision unit](../vision/README.md) is the other place stereo depth runs, as a role of its own on a dedicated board, without OpenCV. A vehicle runs stereo in one or the other.

## Configure it in your vehicle

1. Declare the bridge in an entry of `bridge_firmwares/0` (see [Bridge firmwares](./README.md#bridge-firmwares)).
2. Implement `ros_bridge_config/1` on your vehicle's top-level module.

The callback returns a `%RosBridge.Config{}` per arm:

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

A bare atom is shorthand for `{atom, []}`. An unknown component name raises at boot, so a typo is an error instead of a silently dropped feature.

A vehicle that bundles `RosBridge` in several `bridge_firmwares/0` entries implements `ros_bridge_config/2` instead. It also receives the bridge firmware id, so each entry gets its own components.

The OVCS Mini reference vehicle implements `ros_bridge_config/1`; its target configuration, abridged:

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
- **The node name.** `node_name` is what the bridge announces: the name `ros2 node list` and Foxglove show. It is `ovcs_bridge` by default. Two bridge firmwares on one fabric must each set their own, or they collide in the ROS graph and Foxglove renders them as one node. The OVCS Mini's is `ovcs_bridge_ros`, next to its vision unit's `ovcs_vision`.

## BNO085 reporting

The BNO085 driver enables acceleration, calibrated angular velocity and the game rotation vector at 50 Hz by default. The game vector excludes the magnetometer, so heading is relative and still needs an external position/heading reference for long runs. The driver watches each report independently, retries missing enables and resets an unresponsive stream. A reset changes the sample's orientation reference.

Samples retain calibration accuracy, sequence and local monotonic capture/receipt times. SH-2 base/rebase and delay fields correct the capture estimate, but the I²C polling time is its anchor; hardware interrupt timing and wheel/IMU clock alignment still require measurement. Accuracy is a sensor status, not a covariance estimate. Keep the vehicle stationary during startup calibration and inspect the status and gyro bias before driving.

Driver options include `report_interval_us`, `poll_interval_ms`, `max_packets_per_poll` and `stream_timeout_ms`; pass them as `driver_opts` on `:imu_publisher`. Verify real stream rates and I²C load before selecting 100 Hz.

## Check it end to end

With `./ovcs run <vehicle>` going and the local ROS 2 stack up, the bridge's `/ovcs_heartbeat` appears in `ros2 topic list` and in Foxglove. [Verifying end to end](../ros2/README.md#verifying-end-to-end) has the commands.

## Where next

- [ROS 2](../ros2/README.md): the Zenoh fabric, who publishes which topic, time, the command paths and Nav2.
- [Vision unit](../vision/README.md): stereo depth and object detection, a role of their own.
- [ROS compute node](../ros2/compute_node.md): the machine that runs the Zenoh router on the vehicle.
