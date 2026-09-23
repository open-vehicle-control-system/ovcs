---
title: Testing with CAN
description: Inject single frames with cansend, replay real captures with canplayer, watch what the VMS emits, and read frame YAMLs.
---

During local development none of the CAN traffic is real. The `can-utils` tools let you inject single frames, replay captures from a real car, and watch what the VMS emits, all against the virtual interfaces `./ovcs can setup` creates.

> [!NOTE]
> The tools and the virtual-CAN setup work with any application. The frame ids in the examples (`0x280`, `0x320`) come from the OVCS1 reference application; your application's frames are whatever its `priv/can/` YAMLs declare, and the same commands apply.

## Prerequisites

- Virtual CAN interfaces are up: `./ovcs can setup <app>`, or `./ovcs run <app>`, which does it for you.
- The VMS (or infotainment) side is running; see [Framework components](./applications.md#local-development).
- `can-utils` is installed (`sudo apt install can-utils`): it provides `cansend`, `candump`, `canplayer` and `cangen`.

Each network maps to one interface. The application's `default_can_mapping(:host)` sets the mapping; OVCS1's is `ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4`. A frame sent on the wrong interface is silently ignored.

## Sending single frames

```sh
cansend <interface> <can_id>#<data>
```

The id is hex; the data is hex bytes with no separators. With `./ovcs run ovcs1` going, the handbrake frame on the Polo bus (`polo_drive`, so `vcan2`) changes the handbrake state the VMS and the infotainment report:

```sh
cansend vcan2 320#0002000000000000   # handbrake engaged (byte 1 = 0x02)
cansend vcan2 320#0000000000000000   # handbrake disengaged
```

For your application, pick a frame its VMS **receives** and follow the same pattern. Sending a frame the VMS emits does nothing: the VMS is the one producing it.

## Watching what the VMS emits

```sh
candump vcan2                        # everything on the interface
candump vcan2,280:7FF                # only id 0x280 (mask 7FF: exact match)
candump vcan2,280:7FF,320:7FF        # several ids
candump -L vcan2 > my_recording.log  # record in the log format canplayer reads
```

In OVCS1, `0x280` is the engine status the VMS sends to the Polo instrument cluster: the Leaf motor's rpm, as a little-endian 16-bit integer in bytes 2 and 3, scaled by 0.25. `88 13` reads as `0x1388` = 5000, so 1250 rpm.

> [!TIP]
> `./ovcs attach <app>` has a CAN pane that shows every frame on every declared interface decoded into named signals, using the application's own YAML. It is often faster than reading bytes. See the [CLI reference](../cli/README.md).

## Replaying CAN Dumps

`candumps/` at the repository root holds CAN logs recorded on real vehicles, mostly the OVCS1 Polo (the `tcross` and `obd2` captures come from other cars). Replaying one gives you realistic traffic.

```sh
canplayer -l i -I candumps/candump-standard-test.log vcan2=can0   # loop forever
canplayer      -I candumps/candump-standard-test.log vcan2=can0   # once
```

- `-l i` loops the replay forever.
- `-I <file>` names the dump.
- `vcan2=can0` replays the dump's `can0` onto your `vcan2`. The interface names inside a dump are those of the machine that recorded it, not your networks: check the ids with `head <file>` and map each recorded interface onto the vcan that carries the same network. In `candump-standard-test.log`, `can0` is the Polo bus (`0x320`, `0x470`, `0x5A0`, …), which OVCS1's host mapping puts on `vcan2`; its `can1` traffic matches no current OVCS1 network, so leave it out.

`ls candumps/` lists the scenarios; the names describe what was captured, for instance `candump-leaf-engine-startup-128-then-minus-3.log` or `candump-2025-07-OBD2-tcross.log`.

## Synthesising inputs on the bench

Some behaviour needs a stream of frames rather than one: `cangen` repeats a frame at a fixed gap. Switching control levels on the host, for example, needs a zero-speed stream plus the radio switch frames; the full recipe is in [Driving on the host bench](./vehicle_parameterisation.md#driving-on-the-host-bench).

```sh
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10   # 0x709 every 10 ms, fixed payload
```

## Reading frame definitions

Every frame OVCS understands is described in YAML. Shared per-component specs live in the `ovcs_can` library under [`libraries/ovcs_can/priv/can/components/`](../libraries/ovcs_can/priv/can/components), grouped by manufacturer (`bosch/`, `nissan/`, `orion/`, `volkswagen/`, `vesc/`, `ovcs/`, `obd2/`, …). Each application's topology, which frames run on which network, lives in its package under `vehicles/<name>/priv/can/vms.yml` and `infotainment.yml`, and imports the shared specs:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

A frame definition gives the CAN id, the frequency, and the signals packed inside. A signal is a bit range with a kind and, optionally, a scale and unit. From `0x280_engine_status.yml`:

```yaml
- name: rotations_per_minute
  kind: integer
  unit: rpm
  value_start: 16    # bit offset within the frame data
  value_length: 16   # number of bits
  scale: "0.25"
```

Signed and unsigned integers, big- and little-endian layouts, enums, static fillers and scaled values are supported; the [Cantastic README](https://github.com/open-vehicle-control-system/cantastic) has the full format. [Hardware](./hardware_architecture.md#can-bus-configuration) shows how component and topology files fit together.

## Troubleshooting

### "Cannot find device vcan0"

The virtual interfaces aren't up:

```sh
./ovcs can setup <app>
```

If loading the `vcan` module fails, load the kernel modules first:

```sh
sudo modprobe can
sudo modprobe can_raw
sudo modprobe vcan
```

On an atomic Fedora desktop (Bluefin, Silverblue, …) this has to happen on the host, not inside the distrobox; see [Getting started](./getting_started.md).

### Frames sent, nothing happens

1. The VMS runs with `CAN_NETWORK_MAPPINGS` (or the application's default host mapping) pointing at your virtual interfaces.
2. `VEHICLE` is the application's top-level module name: `Ovcs1`, `OvcsMini`, `Obd2`, or your own.
3. You're sending on the interface that carries the frame's network, and the frame is one the VMS receives.
