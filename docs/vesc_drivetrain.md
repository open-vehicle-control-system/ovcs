# VESC drivetrain

How a traction motor behind a VESC motor controller is driven from the
VMS over CAN, and what has to be set on the VESC for it. The component
is `VmsCore.Components.Vesc.MotorController`; its frames are described
under [Frames](#frames).

## Why a VESC rather than a hobby ESC

A hobby ESC takes a servo pulse and gives nothing back. The VMS has to
guess the edge of motion, cannot ask for a speed, and cannot brake and
reverse without the ESC's own brake-then-reverse sequence getting in
the way. A VESC on the CAN bus closes all three gaps:

- **Closed-loop speed.** `vesc_set_rpm` asks for an electrical rpm and
  the VESC's speed loop holds it under load, so a planner's velocity is
  followed rather than approximated by a pulse width. A zero velocity
  is sent as zero duty, a passive brake that works from any motor
  state; below the loop's minimum erpm the VESC brakes the same way,
  which is why that minimum has to be set below the slowest velocity
  in use (see the settings).
- **Telemetry.** `vesc_status` reports the signed motor rpm and the
  motor current at 50 Hz; `vesc_status_5` adds the battery voltage.
  The rpm is a rotation `OVCS.VehicleMotion` can turn into the
  vehicle's speed, with the direction included, as an alternative to
  the pulse sensor elsewhere in the driveline.
- **Reverse.** A negative rpm is reverse, no brake-then-reverse
  sequence, so the planner may plan in reverse.

The VESC needs a sensored motor (Hall or encoder) for clean starts under
load; with a sensorless motor it still works but starts roughly.

## Wiring

The VESC's CAN H and CAN L go on a bus of the VMS's — on OVCS Mini the
`misc` bus on `spi1.0`, kept apart from the controller and bridge
frames on `ovcs`. It has no termination resistor of its own, so the
bus's existing terminations stay as they are. Its CAN ground is the vehicle ground.
The VESC's own power stays on the traction battery; the VMS does not
switch it.

The VESC does not need the generic controller: it is a CAN node of its
own, commanded straight from the VMS. The controller keeps the steering
servo and whatever else is on its pins.

## VESC Tool settings

Set these once in VESC Tool, after motor detection:

| Setting | Where | Value |
|---------|-------|-------|
| VESC ID | App Settings → General | the id byte of the vehicle's frame wrappers, `1` in the examples below |
| CAN baud rate | App Settings → General | the bus's bitrate, 500 kbps for `misc` on OVCS Mini |
| CAN status message mode | App Settings → General | a mode that includes messages 1 and 5 |
| CAN status rate | App Settings → General | 50 Hz |
| Timeout | App Settings → General | 1000 ms (default); must stay far above the 20 ms command period |
| Timeout brake current | App Settings → General | 0 A, so a lost VMS releases the motor rather than braking |
| Minimum ERPM | Motor Settings → PID Controllers → Speed Controller | below the slowest velocity in use, see below |

The VESC id defaults to one derived from the board's serial number, so
it has to be set explicitly. The 500 kbps baud rate, the 1000 ms
timeout and the 50 Hz status rate are the firmware defaults.

**Minimum ERPM matters.** A speed setpoint whose magnitude is under it
does not run the speed loop at all: a running motor holds zero duty, a
passive brake, and a released motor is not started. The firmware
default is 900 erpm; on a 2-pole-pair
motor geared 11.82:1 to 54.8 mm wheels that is 0.22 m/s, above much of
what a planner commands on its way into a goal — every one of those
velocities would brake instead. Set it to a few tens of erpm; the
speed loop's low end then depends on the motor's sensor, which is what
the bench check below is for.

Motor current, battery current, and erpm limits are set on the VESC in
*Motor Settings* and hold regardless of what the VMS asks for. Set them
for the motor and the battery first; the VMS's own caps come on top.

## Frames

The packets are the VESC firmware's own (`vedderb/bldc`,
`comm/comm_can.c`). Every VESC frame is a 29-bit extended frame whose
identifier is `controller_id | (packet_type << 8)`: the low byte is the
VESC id, the byte above it the packet type. All payloads are
big-endian. The shared library carries the *signals* of each packet and nothing else
(`libraries/ovcs_can/priv/can/components/vesc/*_signals.yml`); the
vehicle topology wraps each one in a frame that names it and sets the
identifier with its VESC's id byte — the way the generic controller's
frames are declared. A second VESC is a second set of wrappers with
another id byte and another name prefix.

Standard and extended frames share the bus without conflict: the
arbitration field differs even when the low 11 bits coincide, and the
receivers on both sides keep them apart — Cantastic keys its
specifications on the SocketCAN `can_id` with `CAN_EFF_FLAG`, and the
generic controller's MCP2517FD filters extended frames out in hardware.

For a VESC with id 1 wrapped under the prefix `vesc`:

| Frame | Id | Signals | Sent by | When |
|-------|----|---------|---------|------|
| `vesc_set_current` | `0x0101` | `set_current_signals.yml` | VMS | no source is selected, or a geared hand in neutral, parking or at rest: zero current releases the motor |
| `vesc_set_current_brake` | `0x0201` | `set_current_brake_signals.yml` | VMS | with gears, a hand pulling the trigger back: braking current, never reverse |
| `vesc_set_duty` | `0x0001` | `set_duty_signals.yml` | VMS | a hand commands: its shaped request in [-1, 1] times the duty cap, signed by the gear when there is one; also a velocity of exactly zero, which brakes |
| `vesc_set_rpm` | `0x0301` | `set_rpm_signals.yml` | VMS | a non-zero velocity commands: electrical rpm, negative for reverse |
| `vesc_status` | `0x0901` | `status_signals.yml` | VESC | 50 Hz: erpm, motor current, duty |
| `vesc_status_5` | `0x1B01` | `status_5_signals.yml` | VESC | 50 Hz: tachometer, input voltage |

The payloads, as the signals files decode them:

| Signals | Packet | Type | Payload |
|---------|--------|------|---------|
| `set_duty_signals.yml` | `CAN_PACKET_SET_DUTY` | 0x00 | duty in [-1, 1] as int32 × 100 000 |
| `set_current_signals.yml` | `CAN_PACKET_SET_CURRENT` | 0x01 | motor current in A as int32 × 1000 |
| `set_current_brake_signals.yml` | `CAN_PACKET_SET_CURRENT_BRAKE` | 0x02 | braking current in A as int32 × 1000 |
| `set_rpm_signals.yml` | `CAN_PACKET_SET_RPM` | 0x03 | electrical rpm as int32 |
| `status_signals.yml` | `CAN_PACKET_STATUS` | 0x09 | erpm int32, motor current int16 × 10, duty int16 × 1000 |
| `status_5_signals.yml` | `CAN_PACKET_STATUS_5` | 0x1B | tachometer int32, input voltage int16 × 10 |

Exactly one command frame is emitted at a time, every
20 ms; `Vesc.MotorController` switches the emitter when the selected
source changes kind. The VESC applies whichever control mode it last
received.

Zero velocity goes out as zero duty rather than zero rpm on purpose.
The VESC only starts its speed loop for a setpoint above *Minimum
ERPM*; below it a running motor holds zero duty, a passive brake, but
a released motor — which is what the release command and the timeout
leave behind — stays released, and a zero rpm would never start it.
Zero duty brakes from any state and leaves the motor running for the
next setpoint.

### Gears for hands

Given `selected_gear_source: Managers.Gear`, a hand's request stops
carrying the direction. The gear does, as on OVCS1: the radio's
direction switch or the gamepad's direction button asks for `:drive`
or `:reverse`, and the gear manager shifts only below 1 km/h with the
trigger released. A positive request then drives in the selected gear;
pulling the trigger back always brakes, with `vesc_set_current_brake`
at up to `:max_brake_current`, and never reverses; a released trigger
lets the motor coast. In `:neutral` and `:parking` a hand can brake but
not drive. A velocity ignores the gear, since its own sign is the
direction.

## Wiring it into a composer

`Vesc.MotorController` takes the place of `Traxxas.MotorController` as the
throttle actuator; the OVCS Mini's composer
(`vehicles/ovcs_mini/lib/ovcs_mini/vms/composer.ex`) is the worked
example. Its frame names follow its process name, so with
`process_name: Vms.Vesc` the topology YAML declares the five frames
under the `vesc_` prefix on the network the VESC is wired to, each
wrapping the shared signals with the VESC's id in the low byte:

```yaml
# vehicles/ovcs_mini/priv/can/vms.yml
can_networks:
  misc:
    bitrate: 500000
    emitted_frames:
      - import!:vesc/0x0001_vesc_set_duty.yml
      - import!:vesc/0x0101_vesc_set_current.yml
      - import!:vesc/0x0201_vesc_set_current_brake.yml
      - import!:vesc/0x0301_vesc_set_rpm.yml
    received_frames:
      - import!:vesc/0x0901_vesc_status.yml
      - import!:vesc/0x1B01_vesc_status_5.yml
```

```yaml
# vehicles/ovcs_mini/priv/can/vesc/0x0301_vesc_set_rpm.yml
---
name: vesc_set_rpm
id: 0x0301
extended: true
frequency: 20
signals: import!:@ovcs_can:can/components/vesc/set_rpm_signals.yml
```

The received wrappers carry `frequency: 20` as well, the period the
frame watcher expects at the VESC's 50 Hz status rate.

The motor controller knows nothing about the vehicle: it takes the
motor rpm at a full linear request and the motor's pole pairs. The
kinematics that turn a speed into that rpm — the pinion to spur ratio,
the transmission, the wheel radius — are the vehicle's, declared once
in the composer and shared with `VehicleMotion`:

```elixir
# Motor turns per wheel turn: the manufacturer's overall ratio for
# the gearing the vehicle runs, 11.82:1 on the stock Slash 4x4.
@motor_to_wheel_ratio 11.82
# Motor rpm at `@max_speed_m_s`, what a full linear request asks for.
@max_motor_rotation_per_minute @max_speed_m_s * 60 /
                                 (2 * :math.pi() * OvcsMini.geometry().wheel_radius) *
                                 @motor_to_wheel_ratio

{Vesc.MotorController,
 %{
   process_name: Vms.Vesc,
   network: :misc,
   selected_control_level_source: Managers.ControlLevel,
   linear_sources: [OVCS.RosVelocityCommand],
   # Drive or reverse from the gear, the trigger pulled back brakes.
   selected_gear_source: Managers.Gear,
   max_brake_current: @max_brake_current,
   max_rotation_per_minute: @max_motor_rotation_per_minute,
   # A 4-pole motor.
   pole_pairs: 2,
   # Duty caps for hands; the hand's own dead zone and expo are an
   # `OVCS.InputCurve` in front of the manager.
   max_throttle: @max_throttle,
   max_reverse: @max_reverse_throttle
 }}
```

`VehicleMotion` takes the motor's rotation through an
`OVCS.RotationFusion`, which couples the VESC with a pulse sensor on
the same shaft. The VESC gives the value, signed and at 50 Hz; the
pulse sensor cross-checks it and takes over when the VESC goes quiet,
signed by the direction the VESC is driven in. When every source reads
within its noise the fused rotation is exactly zero, which
`Managers.ControlLevel`'s standstill gate needs: a stopped VESC still
reports an erpm or two. Every rpm in the fusion's options is of the
output shaft, here the motor:

```elixir
{OVCS.RotationFusion,
 %{
   process_name: Vms.MotorRotation,
   sources: [
     %{source: Vms.Vesc, ratio: 1, signed: true, noise_rpm: 5},
     %{source: OVCS.PulseRotationSensor, ratio: @spur_teeth / @pinion_teeth, signed: false}
   ],
   direction_source: Vms.Vesc,
   cross_check_from_rpm: 450,
   cross_check_tolerance: 0.1,
   cross_check_hold_ms: 1_500
 }},
{OVCS.VehicleMotion,
 %{
   rotation_source: Vms.MotorRotation,
   rotation_to_wheel_ratio: @motor_to_wheel_ratio,
   rotation_signed: true,
   ...
 }}
```

A cross-check fault is published and logged, not acted on: on the
Mini both sources sit upstream of the slipper clutch, so a gap means a
sensor or the gear mesh has failed.

`@max_speed_m_s` is the speed at a linear request of 1 on both sides —
what `RosVelocityCommand` normalises against and what the motor rpm is
derived from — so it is one constant in the composer, not two. Unlike
the PWM throttle's cap, it is a real speed: the VESC holds it.

### Bench checks

The motor-to-wheel ratio and the pole pairs turn the planner's
velocity into the motor rpm the VESC holds, so an error there makes the
vehicle drive at the wrong speed. The check has to come from a source
that does not depend on them: the pulse sensor on the spur, whose
`:rotation_per_minute` is the spur's, independent of anything the VESC
reports. Lift the vehicle, command a known rpm from IEx, and compare
the motor controller's `:rotation_per_minute` with the spur sensor's
times the pinion-to-spur ratio (54/13 above). The rotation fusion runs
the same comparison continuously above `cross_check_from_rpm`. The
fused `:speed` is derived from the motor-to-wheel ratio and proves
nothing about it: that needs a measured distance.

Then find the slowest speed the loop holds cleanly: with the vehicle
lifted, step the rpm setpoint down until the wheels stutter or stop,
and make sure *Minimum ERPM* sits below that and the planner's minimum
velocity sits above it.

## On the host bench

The speed still comes from the pulse counter frame, so the bench setup
in [Vehicle Parameterisation, "Driving on the host
bench"](./vehicle_parameterisation.md#driving-on-the-host-bench) is
unchanged. Nothing emits `vesc_status` on a virtual CAN, so the
motor controller's telemetry reads nil; to see it populated, synthesise a
stationary VESC on the VESC's bus — `vcan1` is `misc` on the Mini — and
the id needs `cangen`'s extended flag:

```bash
cangen vcan1 -e -I 901 -L 8 -D 0000000000000000 -g 20
```

The commands the VMS emits are visible with `candump vcan1` as
`00000001`, `00000101` or `00000301` frames, one of them at a time.

Next: [Vehicle Parameterisation](./vehicle_parameterisation.md)
