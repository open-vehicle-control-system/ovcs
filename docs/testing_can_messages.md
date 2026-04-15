# Testing with CAN Messages

OVCS relies on CAN bus communication. During local development, you can simulate CAN traffic using virtual CAN interfaces and the `can-utils` command-line tools.

## Prerequisites

- Virtual CAN interfaces must be running: `./ovcs can setup <vehicle>`
- The VMS or Infotainment API must be started (see [Applications](./applications.md))
- `can-utils` must be installed: `sudo apt install can-utils`

## Sending Individual CAN Messages

Use `cansend` to send a single CAN frame on a virtual interface:

```sh
cansend <interface> <can_id>#<data>
```

### OVCS1 Examples

The following commands simulate CAN messages as they would appear on the original OVCS1 Polo. Use these to test the VMS and see status changes on the debug dashboard.

#### Handbrake

```sh
# Handbrake engaged
cansend vcan0 320#03027F0100000000

# Handbrake disengaged
cansend vcan0 320#03007F0100000000
```

#### Engine RPM

```sh
# 1250 RPM
cansend vcan0 280#0000881300000000

# 2250 RPM
cansend vcan0 280#0000282300000000
```

## Replaying CAN Dumps

The `candumps/` directory at the repository root contains CAN bus capture logs recorded from the real OVCS1 vehicle. You can replay these to simulate realistic CAN traffic.

### Replay in a loop

```sh
canplayer -l i -I candumps/candump-standard-test.log vcan0=can0 vcan1=can1
```

This command:
- `-l i` -- loops the replay infinitely
- `-I <file>` -- reads from the specified dump file
- `vcan0=can0` -- maps `can0` from the dump to `vcan0` on your host
- `vcan1=can1` -- maps `can1` from the dump to `vcan1` on your host

### Replay once

```sh
canplayer -I candumps/candump-standard-test.log vcan0=can0 vcan1=can1
```

### Available CAN dumps

The `candumps/` directory contains recordings from various test scenarios. Use `ls candumps/` to see all available files. Notable dumps include:

- `candump-standard-test.log` -- Standard driving scenario with all systems active
- `eps_tcross_*.log` -- Electric power steering data
- `fool_sequence_*.log` -- Specific test sequences

## Monitoring CAN Traffic

### Watch all messages on an interface

```sh
candump vcan0
```

### Watch with filtering

```sh
# Only show messages with CAN ID 0x280 (engine status)
candump vcan0,280:7FF

# Show messages from multiple IDs
candump vcan0,280:7FF,320:7FF
```

### Record a CAN dump

```sh
candump -L vcan0 > my_recording.log
```

The `-L` flag outputs in the log file format compatible with `canplayer`.

## Understanding CAN Frame Definitions

CAN frame specifications are defined in YAML files. Shared per-component specs live in [`libraries/ovcs_can/priv/can/components/`](../libraries/ovcs_can/priv/can/components); each vehicle's CAN topology (which frames run on which networks) lives in its package under `vehicles/<name>/priv/can/{vms,infotainment}.yml`. Each YAML file defines a frame's CAN ID, data length, and the signals packed within it.

For example, a signal definition:

```yaml
- name: counter
  kind: integer
  value_start: 0     # Bit offset within the frame data
  value_length: 8    # Number of bits
```

See the [Hardware Architecture](./hardware_architecture.md#can-bus-configuration) documentation for the full CAN configuration structure.

## Troubleshooting

### "Cannot find device vcan0"

Virtual CAN interfaces are not set up. Run:

```sh
./ovcs can setup <vehicle>   # e.g. ovcs1 | ovcs_mini | obd2
```

If `vcan` module loading fails, you may need to load the kernel modules first:

```sh
sudo modprobe can
sudo modprobe can_raw
sudo modprobe vcan
```

### Messages sent but nothing happens in the dashboard

Check that:
1. The VMS API is running with the correct `CAN_NETWORK_MAPPINGS` pointing to your virtual interfaces.
2. The `VEHICLE` environment variable is set to the vehicle package's top-level module name (e.g., `Ovcs1`, `OvcsMini`, `Obd2`).
3. You are sending messages on the correct virtual interface for the CAN network you want to target.

Next: [Hardware Architecture](./hardware_architecture.md)
