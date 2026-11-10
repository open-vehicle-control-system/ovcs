---
title: Command paths
description: The two ways a ROS node commands your vehicle, joystick positions and planner velocities, how the VMS drives the simulator, the vehicle motion it reports back, and the switches that decide who commands.
---

A ROS node never drives an actuator. It sends one of two command frames to the VMS on the `ovcs` bus, and the VMS decides whether it is in force. This page follows both paths, and the loop the VMS closes with the simulator. The fabric they run on is in [ROS 2](./README.md).

A command reaches the drivetrain one of two ways, a joystick's or a planner's, on the vehicle and in the simulator alike.

```text
On the vehicle (OVCS Mini)
  joy node (base station) ──/joy/<profile>──► Consumers.Joy ──0x2B0──► VMS: RosActuatorCommand.*
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

## The VMS drives the simulator

In the simulator the same loop drives Gazebo. Simulated hardware (the `:simulated_hardware` component: `SimulatorCore.Hardware` with `RosBridge.Simulator.World` as its world) stands in for the hardware on virtual CAN: it reads what the VMS commands, hands Gazebo the resulting motion, and reports what the real hardware would.

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

The simulated hardware is framework; what it emulates is the vehicle's. Each piece of hardware is a `SimulatorCore.SimulatedComponent`, the inverse of the VMS component that drives it, named after it and reading and writing its frames by name: `SimulatedComponents.Vesc.MotorController`, `SimulatedComponents.OVCS.GenericController`, `SimulatedComponents.Traxxas.Steering` and `SimulatedComponents.OVCS.RadioControl` are the OVCS Mini reference vehicle's set. A vehicle with other hardware adds simulated components; `SimulatorCore.Vehicle`, the motion they act on, knows none of them. The OVCS Mini wires it into its `ros` bridge with `OVCS_SIM`, in `ros_bridge_simulation_config/0`, and declares its frames in `priv/can/bridges/ros_simulated_components.yml`, merged into the bridge's CAN topology on the host only.

A frame from the VMS only updates the command its simulated component holds. The work happens on a 20 ms wall-clock tick:

1. Each simulated component turns its command into actuations on `SimulatorCore.Vehicle`: a speed setpoint, an acceleration from a motor current, a deceleration from a brake, a steering angle.
2. The vehicle steps, in three parts:
   - **What to ask for.** The actuations become a commanded speed and steering angle. A setpoint is taken as it is; otherwise the speed changes by the drive, less any brake and the rolling resistance, over the tick.
   - **What the wheels did.** Their turn since the last tick is the change in the `:wheel_joints`' mean position on `/joint_states`, cumulative, so samples arriving late or in bursts lose nothing. The measured speed is that distance per wall second, smoothed by a filter that keeps the total.
   - **Keeping the request honest.** The commanded speed may lead the measured one by at most 0.25 m/s in its own direction: against a wall the wheels stall and the request holds at 0.25 m/s instead of winding up. The measurement only ever lowers the request: a burst of late samples reads as a speed spike, and a car asked to stop still stops.
3. Each simulated component reports what its hardware would measure: counters from the wheel turns and rates from the measured speed, into its CAN frames, which Cantastic sends on their own timers.
4. The commanded speed and its Ackermann yaw rate go to Gazebo on `/simulator/drive`.

`SimulatorCore.Vehicle`'s documentation works three of these steps through with the OVCS Mini's numbers.

Three things are particular to the simulator:

- **Gazebo is told the motion, and measures it back.** `AckermannSteering` drives the wheels toward the commanded speed, but no harder than their joints' effort limit: set to what the motor gives each wheel, a blocked wheel stalls instead of spinning. What the simulated components report follows the wheels, as the vehicle's sensors do, so a wheel spinning in place reads as moving.
- **One clock, the VMS's.** Distances come from Gazebo's wheels and rates are per wall second, so the counters match Gazebo, the rates match the counters however fast Gazebo runs, and the VMS's cross-check between a VESC and a pulse sensor holds. Below real time, `/odom`'s pose still advances with Gazebo, but its twist, the VMS's speed per wall second, reads slower than Nav2 commanded.
- **The switches are scripted.** `SimulatedComponents.OVCS.RadioControl` plays the vehicle's script of RC channel positions once the VMS's `vms_status` appears, and rewinds it when that frame stops, so a restarted VMS goes through the same transitions. The OVCS Mini's moves channel 6 through `:radio` to `:ros`, then channel 5 to the commander `OVCS_SIMULATOR_COMMANDER` names (`autonomous` by default).

## Ground truth

`AckermannSteering`'s own odometry follows the wheels, not the body, so it is not where the model is. `/simulator/odom` is: the model's pose and twist as the physics has it, from Gazebo's `OdometryPublisher` system in the model. Nothing reads it: it is there to compare with `/odom`. Its origin is not the bridge's, whose `/odom` starts wherever the vehicle was when the bridge did, so compare displacements from a common start rather than raw poses.

## The vehicle's own motion (0x60B)

Nav2 consumes `/odom` and the `odom → base_link` transform. On the vehicle, the VMS emits `vehicle_motion` (`0x60B`): the speed `OVCS.VehicleMotion` computes from a driveline rotation through the gearing and wheel size, plus the commanded steering angle, the distance the wheels have rolled (a 16-bit millimetre counter), validity flags and a per-fresh-sample sequence, at 50 Hz. The OVCS Mini takes a signed rotation from its VESC, cross-checked by a spur pulse sensor; a source that can't sign its rotation takes the sign of the throttle request the control level manager selected.

`RosBridge.Publishers.Odometry` integrates the distance between two samples along the BNO085's heading, and publishes both topics with one stamp, the arrival time, on each fresh sample. The distance rather than the speed: the OVCS Mini's speed is its VESC's tachometer differenced over a 200 ms window, which describes the car 100 ms ago, and position integrated from it lagged the camera by as much. The speed is the fallback while the distance is invalid. When the VMS loses its speed, or the frame goes stale, the publisher goes *silent* rather than holding: tf lookups never extrapolate past the newest stamp, so a stopped publisher halts Nav2 instead of letting it plan against a frozen pose.

One odometry owner per fabric: the bridge's, against the simulator as on the vehicle. The steering plugin's odometry is not bridged, because two publishers would hand every consumer two contradictory poses.

## The actuator command (0x2B0)

`RosBridge.Consumers.Joy` subscribes to `/joy/<profile>`, one topic per joy profile, and writes `ros_actuator_command`: `steering` and `throttle` in `[-1, 1]` at 0.001 resolution, mapped from the controller's axes by its profile, a `direction` (for vehicles where reverse is a gear and a negative throttle brakes), and a `sequence`. The VMS components `OVCS.RosActuatorCommand.*` read them as normalised actuator requests: *what a joystick means*, positions, not physics. An axis outside `[-1, 1]` is clamped (Cantastic truncates a signed field silently and the value would come back with the wrong sign), and a `Joy` with too few axes reads as centre.

## The velocity command (0x2B1)

`RosBridge.Consumers.Velocity` subscribes to a velocity topic and writes `ros_velocity_command`: `linear` (m/s, 0.01) and `angular` (rad/s, 0.001) as signed 16-bit integers, plus a `sequence`. This is *what a planner means*: a physical quantity, with the kinematics solved **once, in the VMS**, by `OVCS.RosVelocityCommand` against the vehicle's `geometry/0`:

```text
ω is first clamped to |v| / (wheelbase / tan(steering_limit))
δ = atan(wheelbase · ω / v)      clamped to steering_limit
```

A yaw rate the steering cannot achieve collapses to full lock rather than an error branch. Forward and reverse are the sign of `linear`. The bridge never learns a wheelbase, so any commander (Nav2, a remote operator, a test rig) gets correct kinematics for whatever vehicle it drives.

## The sequence

`Cantastic.Emitter` retransmits a frame at its period whether or not anything new was written, so a frame on time proves only that the bridge is alive. The bridge increments `sequence` once per ROS sample. On the VMS, `RosCommand.Freshness` treats a sequence that stops changing as a lost input and zeroes the throttle or the velocity; a retransmitted frame is never applied as fresh input. The bridge also watches its own input (`RosBridge.InputWatchdog`) to zero what it emits and log why, but the safety decision does not depend on it.

## Two switches, two questions

`Managers.ControlLevel` reads two independent switches on the RC transmitter, because *authority* and *autonomy* are different questions:

| Component | Values | Answers |
|---|---|---|
| `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` | who has authority |
| `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` | which ROS node, when ROS does |

`:ros` means "commands come from the ROS bridge", not "the car drives itself": a human on a gamepad and a planner reach the VMS over identical topics and frames. `:ros` is reachable only from `:radio`, both switches only *request*, and arming `:autonomous` needs a standstill while handing back to `:teleop` is immediate. The state machine, each reference vehicle's channel layout and the bench recipe are in [How the VMS works](../vms/how_it_works.md#control-levels).

## Two things that fail silently

- **The wrong message type decodes as nonsense.** `Twist.parse/1` accepts any body of 48 bytes or more, so a 72-byte `TwistStamped` decodes as six float64s read out of the header (denormals near 1.0e-273): the vehicle ignores every command while every watchdog reports a healthy stream. `Ros2Zenoh.Client` warns about surplus bytes after a successful parse, which catches it. The simulator's mirror image: a `Twist` bridge fed `TwistStamped` never fires, and a healthy-looking Nav2 moves nothing.
- **A quiet commander leaves its last command on the bus.** The emitter retransmits on a timer; the `sequence` above is the defence.

## Where next

- [Control levels](../vms/how_it_works.md#control-levels): how the VMS arbitrates between commanders.
- [ROS bridge](../bridges/ros.md): the consumers that emit these frames.
- [Nav2, as configured here](./README.md#nav2-as-configured-here): the planner behind the velocity command.
