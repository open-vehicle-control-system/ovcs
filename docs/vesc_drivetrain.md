# VESC drivetrain

How a traction motor behind a VESC motor controller is driven from the
VMS over CAN, and what has to be set on the VESC for it. The component
is `VmsCore.Components.Vesc.MotorController`; the frames are in
[`libraries/ovcs_can/priv/can/components/vesc/`](../libraries/ovcs_can/priv/can/components/vesc/README.md).

## Why a VESC rather than a hobby ESC

A hobby ESC takes a servo pulse and gives nothing back. The VMS has to
guess the edge of motion, cannot ask for a speed, and cannot brake and
reverse without the ESC's own brake-then-reverse sequence getting in
the way. A VESC on the CAN bus closes all three gaps:

- **Closed-loop speed.** `vesc_set_rpm` asks for an electrical rpm and
  the VESC's speed loop holds it under load, so a planner's velocity is
  followed rather than approximated by a pulse width. Below the loop's
  minimum erpm the VESC holds zero duty instead, a passive brake, which
  is how a zero request stops the vehicle — and why that minimum has to
  be set below the slowest velocity in use (see the settings).
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

The VESC's CAN H and CAN L go on the `ovcs` bus like any other node. It
has no termination resistor of its own, so the bus's existing
terminations stay as they are. Its CAN ground is the vehicle ground.
The VESC's own power stays on the traction battery; the VMS does not
switch it.

The VESC does not need the generic controller: it is a CAN node of its
own, commanded straight from the VMS. The controller keeps the steering
servo and whatever else is on its pins.

## VESC Tool settings

Set these once in VESC Tool, after motor detection:

| Setting | Where | Value |
|---------|-------|-------|
| VESC ID | App Settings → General | `1` (the id baked into the frame files) |
| CAN baud rate | App Settings → General | the `ovcs` bus's bitrate, 500 kbps on OVCS Mini |
| CAN status message mode | App Settings → General | a mode that includes messages 1 and 5 |
| CAN status rate | App Settings → General | 50 Hz |
| Timeout | App Settings → General | 1000 ms (default); must stay far above the 20 ms command period |
| Timeout brake current | App Settings → General | 0 A, so a lost VMS releases the motor rather than braking |
| Minimum ERPM | Motor Settings → PID Controllers → Speed Controller | below the slowest velocity in use, see below |

The VESC id defaults to one derived from the board's serial number, so
it has to be set explicitly. The 500 kbps baud rate, the 1000 ms
timeout and the 50 Hz status rate are the firmware defaults.

**Minimum ERPM matters.** A speed setpoint whose magnitude is under it
does not run the speed loop at all: the VESC holds zero duty, which is
a passive brake. The firmware default is 900 erpm; on a 2-pole-pair
motor geared 11.3:1 to 54.8 mm wheels that is 0.23 m/s, above much of
what a planner commands on its way into a goal — every one of those
velocities would brake instead. Set it to a few tens of erpm; the
speed loop's low end then depends on the motor's sensor, which is what
the bench check below is for.

Motor current, battery current, and erpm limits are set on the VESC in
*Motor Settings* and hold regardless of what the VMS asks for. Set them
for the motor and the battery first; the VMS's own caps come on top.

## Frames

Every VESC frame is a 29-bit extended frame; the low byte of its
identifier is the VESC id and the byte above it the packet type. The
frame files pin the id at 1. A second VESC on the bus needs its own set
of files with the id byte changed, as Cantastic identifiers are static.

Standard and extended frames share the bus without conflict: the
arbitration field differs even when the low 11 bits coincide, and the
receivers on both sides keep them apart — Cantastic keys its
specifications on the SocketCAN `can_id` with `CAN_EFF_FLAG`, and the
generic controller ignores extended frames outright.

| Frame | Id | Sent by | When |
|-------|----|---------|------|
| `vesc_set_current` | `0x0101` | VMS | no source is selected: zero current releases the motor |
| `vesc_set_duty` | `0x0001` | VMS | a hand commands: duty in [-1, 1] through the feel curve |
| `vesc_set_rpm` | `0x0301` | VMS | a velocity commands: electrical rpm, negative for reverse |
| `vesc_status` | `0x0901` | VESC | 50 Hz: erpm, motor current, duty |
| `vesc_status_5` | `0x1B01` | VESC | 50 Hz: tachometer, input voltage |

Exactly one of the three command frames is emitted at a time, every
20 ms; `Vesc.MotorController` switches the emitter when the selected source
changes kind. The VESC applies whichever control mode it last received.

## Wiring it into a composer

`Vesc.MotorController` takes the place of `Traxxas.Throttle` as the
throttle actuator. The topology YAML imports the five frames, three
emitted and two received:

```yaml
emitted_frames:
  - import!:@ovcs_can:can/components/vesc/0x0001_vesc_set_duty.yml
  - import!:@ovcs_can:can/components/vesc/0x0101_vesc_set_current.yml
  - import!:@ovcs_can:can/components/vesc/0x0301_vesc_set_rpm.yml
received_frames:
  - import!:@ovcs_can:can/components/vesc/0x0901_vesc_status.yml
  - import!:@ovcs_can:can/components/vesc/0x1B01_vesc_status_5.yml
```

The motor controller knows nothing about the vehicle: it takes the
motor rpm at a full linear request and the motor's pole pairs. The
kinematics that turn a speed into that rpm — the pinion to spur ratio,
the transmission, the wheel radius — are the vehicle's, declared once
in the composer and shared with `VehicleMotion`:

```elixir
# Motor turns per wheel turn: spur teeth over pinion teeth, both
# counted on the vehicle, times the transmission's fixed 2.72.
@motor_to_wheel_ratio 54 / 13 * 2.72
# Motor rpm at `@max_speed_m_s`, what a full linear request asks for.
@max_motor_rotation_per_minute @max_speed_m_s * 60 /
                                 (2 * :math.pi() * OvcsMini.geometry().wheel_radius) *
                                 @motor_to_wheel_ratio

{Vesc.MotorController,
 %{
   selected_control_level_source: Managers.ControlLevel,
   linear_sources: [OVCS.RosVelocityCommand],
   max_rotation_per_minute: @max_motor_rotation_per_minute,
   # A 4-pole motor.
   pole_pairs: 2,
   # The feel curve for hands, see Traxxas.Throttle.
   deadzone: @throttle_deadzone,
   expo: @throttle_expo,
   max_throttle: @throttle_max,
   max_reverse: @throttle_max_reverse
 }}
```

`VehicleMotion` may then take its rotation from the motor rather than
the pulse sensor — signed, so reverse needs no inference from the
command:

```elixir
{OVCS.VehicleMotion,
 %{
   rotation_source: Vesc.MotorController,
   rotation_to_wheel_ratio: @motor_to_wheel_ratio,
   rotation_signed: true,
   wheel_radius: OvcsMini.geometry().wheel_radius,
   ...
 }}
```

`@max_speed_m_s` is the speed at a linear request of 1 on both sides —
what `RosVelocityCommand` normalises against and what the motor rpm is
derived from — so it is one constant in the composer, not two. Unlike
the PWM throttle's cap, it is a real speed: the VESC holds it.

### Bench checks

`motor_to_wheel_ratio` and `pole_pairs` turn the planner's velocity
into the motor rpm the VESC holds, so an error there makes the vehicle
drive at the wrong speed — and the pulse speed sensor, which does not
depend on them, will show it. Check once: drive at a fixed velocity
under the planner and compare the sensor's `:speed` with what was
asked; or lift the vehicle, command a known rpm from IEx, and compare
the sensor's `:wheel_rotation_per_minute` with the motor controller's
`:rotation_per_minute` over the ratio.

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
stationary VESC — the id needs `cangen`'s extended flag:

```bash
cangen vcan0 -e -I 901 -L 8 -D 0000000000000000 -g 20
```

The commands the VMS emits are visible with `candump vcan0` as
`00000001`, `00000101` or `00000301` frames, one of them at a time.

Next: [Vehicle Parameterisation](./vehicle_parameterisation.md)
