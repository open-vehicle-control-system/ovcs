# VESC CAN frames

Frames spoken by a motor controller running the VESC firmware
(`vedderb/bldc`), as defined in its `comm/comm_can.c`.

Every VESC frame is a 29-bit *extended* frame whose identifier is
`controller_id | (packet_type << 8)`: the low byte is the VESC's own id
(App Settings → General → *VESC ID* in VESC Tool), the byte above it is
the packet type. All payloads are big-endian. The files here are written
for a VESC with id **1**; a second VESC on the same bus needs its own
copies with the id byte changed, since Cantastic identifiers are static.

| File | Packet | Direction | Payload |
|------|--------|-----------|---------|
| `0x0001_vesc_set_duty.yml` | `CAN_PACKET_SET_DUTY` (0x00) | VMS → VESC | duty [-1, 1] as int32 × 100 000 |
| `0x0101_vesc_set_current.yml` | `CAN_PACKET_SET_CURRENT` (0x01) | VMS → VESC | motor current in A as int32 × 1000 |
| `0x0301_vesc_set_rpm.yml` | `CAN_PACKET_SET_RPM` (0x03) | VMS → VESC | electrical rpm as int32 |
| `0x0901_vesc_status.yml` | `CAN_PACKET_STATUS` (0x09) | VESC → VMS | erpm int32, motor current int16 × 10, duty int16 × 1000 |
| `0x1B01_vesc_status_5.yml` | `CAN_PACKET_STATUS_5` (0x1B) | VESC → VMS | tachometer int32, input voltage int16 × 10 |

The VESC stops the motor when no command has arrived for its
*timeout* (App Settings → General, 1000 ms by default), so a command
frame must be emitted continuously while driving. The status frames are
only sent when *Send CAN status* is enabled with a mode that includes
messages 1 and 5, at the configured *CAN status rate*; the received
specs below expect 50 Hz.

Standard 11-bit frames and these extended frames coexist on one bus:
the arbitration field of an extended frame is distinct even when the
low 11 bits match a standard identifier, and Cantastic keys its
specifications on the full SocketCAN `can_id` (with `CAN_EFF_FLAG`).
