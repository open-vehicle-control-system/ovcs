# VESC CAN frames

Signals spoken by a motor controller running the VESC firmware
(`vedderb/bldc`), as defined in its `comm/comm_can.c`.

Every VESC frame is a 29-bit *extended* frame whose identifier is
`controller_id | (packet_type << 8)`: the low byte is the VESC's own id
(App Settings → General → *VESC ID* in VESC Tool), the byte above it is
the packet type. All payloads are big-endian.

The id byte is a fact about one vehicle's wiring, so these files carry
the *signals* only, the way the generic controller's do. The vehicle
topology wraps each one in a frame that names it and sets its
identifier, with the VESC id in the low byte — id 1 here — and
`extended: true`:

```yaml
---
name: vesc_set_rpm
id: 0x0301
extended: true
frequency: 20
signals: import!:@ovcs_can:can/components/vesc/set_rpm_signals.yml
```

A second VESC on the bus is a second set of wrappers with another id
byte and another name prefix, and a second `Vesc.MotorController`
with its own `process_name`.

| File | Packet | Type | Direction | Payload |
|------|--------|------|-----------|---------|
| `set_duty_signals.yml` | `CAN_PACKET_SET_DUTY` | 0x00 | VMS → VESC | duty [-1, 1] as int32 × 100 000 |
| `set_current_signals.yml` | `CAN_PACKET_SET_CURRENT` | 0x01 | VMS → VESC | motor current in A as int32 × 1000 |
| `set_rpm_signals.yml` | `CAN_PACKET_SET_RPM` | 0x03 | VMS → VESC | electrical rpm as int32 |
| `status_signals.yml` | `CAN_PACKET_STATUS` | 0x09 | VESC → VMS | erpm int32, motor current int16 × 10, duty int16 × 1000 |
| `status_5_signals.yml` | `CAN_PACKET_STATUS_5` | 0x1B | VESC → VMS | tachometer int32, input voltage int16 × 10 |

The VESC stops the motor when no command has arrived for its
*timeout* (App Settings → General, 1000 ms by default), so a command
frame must be emitted continuously while driving: the wrappers declare
`frequency: 20`. The status frames are only sent when *Send CAN status*
is enabled with a mode that includes messages 1 and 5, at the
configured *CAN status rate*; the received wrappers expect 50 Hz.

Standard 11-bit frames and these extended frames coexist on one bus:
the arbitration field of an extended frame is distinct even when the
low 11 bits match a standard identifier, and Cantastic keys its
specifications on the full SocketCAN `can_id` (with `CAN_EFF_FLAG`).
