# OVCS Mini

Vehicle package for **OVCS Mini** — a Traxxas 4WD RC car running the full
OVCS software/hardware stack. Used for safe development and testing of
radio-control and ROS2 features before deploying to OVCS1.

This directory is a standalone Mix app implementing the
[`OvcsVehicle`](../../libraries/ovcs_vehicle) behaviour. Select it with
`VEHICLE=OvcsMini` (or pass `ovcs_mini` to the `ovcs` CLI).

OVCS Mini has **no infotainment side** — there's no head unit on the RC
car. The `infotainment/0` callback is omitted, so the infotainment
firmware is never built for this vehicle.

## What this package contributes

| Side | Composer | Nerves target |
|------|----------|---------------|
| VMS | `OvcsMini.Vms.Composer` | `:ovcs_base_can_system_rpi4` |
| Radio-control bridge | `RadioControlBridge` | `:ovcs_base_can_system_rpi3a` |
| ROS bridge | `RosBridge` | `:ovcs_base_can_system_rpi4` |
| Perception bridge (`ros_perception`) | `RosBridge` | `:rpi5` |

Two CAN buses: `ovcs` carries the VMS, the main generic controller and
the CAN-connected bridges; `misc`, on the VMS's second SPI CAN
controller, carries only the traction motor's VESC. The perception
bridge has no CAN controller: it reaches the vehicle over Zenoh.

## Quick start

```sh
../../ovcs run ovcs_mini                 # provision vcan + spawn VMS + bridge BEAMs
../../ovcs attach ovcs_mini
../../ovcs build ovcs_mini vms
../../ovcs build ovcs_mini bridge-radio_control
../../ovcs build ovcs_mini bridge-ros
../../ovcs build ovcs_mini bridge-ros_perception
```

Before the first build, copy `.env.exs.example` to `.env.exs` (gitignored).

## Layout

```
lib/ovcs_mini.ex                   — OvcsVehicle impl
lib/ovcs_mini/vms/                 — VMS-side composer + dashboard pages
priv/can/vms.yml                   — VMS CAN topology (`ovcs` and `misc` buses)
priv/can/generic_controller/       — Per-controller frame wirings
priv/firmware/{vms,bridges}/       — Per-side fwup overrides
nav2/                              — Nav2 parameters + behaviour trees (compute node, local stacks)
description/                       — Gazebo model + simulation.yaml (simulator)
foxglove/                          — Foxglove layouts
```

## Navigation

`nav2/` holds the parameters and the two behaviour trees the framework's Nav2 image loads; [ROS 2 and the simulator](../../docs/ros2_simulator.md#nav2-as-configured-here) has how, and what any Ackermann vehicle needs. What is particular to this car:

- **Stereo is the forward obstacle source.** Both costmaps mark `/stereo/points` between 12 cm and 60 cm above the ground, up to 3 m: a glossy floor's reflections read 7–10 cm high, so lower obstacles go unseen. The global costmap clears by raytracing to 3.5 m. The local costmap uses the spatio-temporal voxel layer: its marks expire after 15 s, and faster inside the camera's frustum (0.55–3 m, the matched part of the image) when they are no longer seen, because a forward-only camera never looks again at what it turned away from. A voxel becomes an obstacle only after three clouds have hit it, and a denoise layer in both costmaps drops obstacle groups smaller than five cells: stereo mismatches rarely repeat in the same place or form large groups, walls and furniture do. Without the perception pipeline running they stay inflation-only, and nothing is avoided.
- **The lidar sees all around.** Its `/scan` adds a 360° plane at its height, marked up to 4 m and cleared up to 5 m, after the denoise layer, so a chair leg one cell wide stays. A bin that got no return is `+Inf`, which `inf_is_valid` clears through; an unmeasured bin is 0.0 and ignored.
- **The rear ultrasonics see below the lidar's plane,** through `RangeSensorLayer`, also after the denoise layer: a close obstacle is an arc of two or three cells.
- **A 0.15 m/s floor, in the VMS.** Below its Minimum ERPM (300) the Mini's VESC brakes instead of driving, 0.07 m/s through the gearing ([VESC drivetrain](../../docs/vesc_drivetrain.md)). `RosVelocityCommand`'s `:min_speed_m_s` drives any slower non-zero velocity at 0.15 m/s, so a planner easing in near its goal neither stops and restarts the car nor loses a slow turn. `velocity_smoother`'s `deadband_velocity` is only 0.02 m/s: a wider band zeroed MPPI's slow speeds while passing their yaw rate, which a car cannot turn without moving. DriveOnHeading floors at `minimum_speed: 0.10`.
- **Reverse at up to 0.3 m/s, forward at 0.8 m/s, 1 m/s².** Behind the car only the lidar and the two rear ultrasonics see, so MPPI's `vx_min` is −0.3 m/s and `PreferForwardCritic` keeps reversing a last resort. `vx_max` is 0.8 m/s, and acceleration 1 m/s² (braking 2): from standstill MPPI reaches two steps of `ax_max × model_dt`, 0.20 m/s.
- **`BackUp` reverses 30 cm, at 0.10 m/s,** which the VMS drives at its 0.15 m/s floor. A car that cannot turn tighter than its radius otherwise stays stuck facing an obstacle. The rear ultrasonics reach the costmaps through Nav2's `RangeSensorLayer`, which ignores REP 117's `+Inf` and clears only on a reading of exactly `max_range`: their `range_publisher` entries set `beyond_range: :max_range`.

## In the simulator

`description/` is the Gazebo model ([Simulation](../../compose/local/simulation/README.md)); `ros_bridge_simulation_config/0` in `lib/ovcs_mini.ex` and `priv/can/bridges/ros_simulated_components.yml` wire the simulated hardware to it.

| Sensor | Gazebo topic | Model | Republished on |
|---|---|---|---|
| BNO085 IMU | `/imu_raw` | IMU sensor, 100 Hz | `/imu` |
| RPLIDAR C1 | `/scan_raw` | 500-ray `gpu_lidar`, 0.05–12 m, 10 Hz | `/scan` |
| Two rear A02YYUW | `/ultrasound/rear_{left,right}_raw` | a 13-ray, 60° `gpu_lidar` fan each, 0.03–4.5 m, 10 Hz | `/ultrasound/rear_{left,right}` |

- **The wheels stall.** Each wheel joint's effort limit, `wheel_max_torque` in `description/ovcs_mini.urdf.xacro`, is what the simulated VESC's 10 A of motor current gives a wheel. Commanded at 0.3 m/s against `workshop.sdf`'s first box, the wheels stalled and the bridge's `/odom` stopped 1.8 cm short of the model.

Deploy the compute node with `../../ovcs compute push ovcs_mini <fleet>`.

See [`docs/hardware.md`](../../docs/hardware.md#ovcs-mini-hardware)
for the RC-car hardware breakdown.
