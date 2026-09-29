---
title: CAN frames and topology
description: How your vehicle declares its CAN networks and frames in Cantastic YAML, how the bit layout compares with DBC, and how to reuse the shared component specs.
---

Every frame OVCS sends or understands is declared in YAML and decoded by [Cantastic](https://github.com/open-vehicle-control-system/cantastic), the framework's CAN library. Your vehicle's package holds the topology (which networks exist, which frames run on each, in which direction); the framework's [`ovcs_can`](../libraries/ovcs_can/README.md) library holds reusable frame and signal specs for the components the reference vehicles use. This page is the reference for that YAML: networks, frames, signals, bit numbering for readers coming from DBC, imports, and how networks meet interfaces. The examples come from the OVCS1 and OVCS Mini reference vehicles; the format is the same for your vehicle.

## Networks and the `ovcs` bus

A topology file is a map of networks under `can_networks`. Each network has a `bitrate` in bit/s and up to three lists: `emitted_frames`, `received_frames`, and `obd2_requests` (diagnostics, covered in [the OBD2 reference vehicle](./obd2.md)). This is the OVCS Mini reference vehicle's [`vms.yml`](../vehicles/ovcs_mini/priv/can/vms.yml), shortened:

```yaml
can_networks:
  ovcs:
    bitrate: 500000
    emitted_frames:
      - import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
      - import!:generic_controller/0x702_main_controller_digital_pin_request.yml
    received_frames:
      - import!:generic_controller/0x701_main_controller_alive.yml
      - import!:@ovcs_can:can/components/ovcs/0x2B1_ros_velocity_command.yml
  misc:
    bitrate: 500000
    emitted_frames:
      - import!:vesc/0x0001_vesc_set_duty.yml
    received_frames:
      - import!:vesc/0x0901_vesc_status.yml
```

`bitrate` is required. It is applied only when Cantastic sets the interface up itself (`setup_can_interfaces: true`, which the VMS and infotainment firmwares set on Nerves targets), with `ip link set <iface> type can bitrate <bitrate>`; virtual `vcan` interfaces ignore it. Every node on one physical bus must declare the same value.

Every vehicle declares a network named `ovcs`. It is not a convention: the framework's own components address it by name. `VmsCore.Status` emits `vms_status` (0x1A0) on `:ovcs`, `OVCS.GenericController` talks to the controllers on it, the infotainment and the bridges read and write it. Your manufacturer buses are yours to name and size; OVCS1's five-bus layout is described in [Hardware](./hardware.md#worked-example-the-ovcs1-reference-vehicle).

Each side of the vehicle runs its own Cantastic instance with its own file: `priv/can/vms.yml` for the VMS, `infotainment.yml` for the head unit, `bridges/<id>.yml` per bridge firmware. Each file declares only the frames that side uses, and a frame the VMS emits is a received frame in the infotainment's file. The directory layout is in [Hardware](./hardware.md#can-bus-configuration).

## Frames

A frame file names the frame, gives its identifier, its period, and its signals. From [`0x1A0_vms_status.yml`](../libraries/ovcs_can/priv/can/components/ovcs/0x1A0_vms_status.yml):

```yaml
name: vms_status
id: 0x1A0
frequency: 100
allowed_frequency_leeway: 200
allowed_missing_frames: 10
signals:
  - name: status
    kind: enum
    value_start: 0
    value_length: 8
    mapping:
      0x00: OK
      0x01: RESETTING
      0xFF: FAILURE
  # ...
```

| Key | Meaning | Default |
|---|---|---|
| `name` | The name your code uses for the frame | required |
| `id` | CAN identifier, up to `0x7FF` | required |
| `extended` | `true` for a 29-bit identifier, up to `0x1FFFFFFF` | `false` |
| `frequency` | **Period in milliseconds**, despite the name | required when emitted |
| `allowed_frequency_leeway` | Milliseconds added to `frequency` before a frame counts as late | `10` |
| `allowed_missing_frames` | Late checks tolerated before subscribers are told | `5` |
| `required_on_time_frames` | On-time checks needed before a frame counts as alive | `5` |
| `signals` | The signal list | `[]` |

Any other key is rejected at boot with `[Yaml configuration error]`. An id above `0x7FF` without `extended: true` is rejected too. Standard and extended frames share a bus, and Cantastic keys specs on the SocketCAN `can_id` with the extended flag, so a standard and an extended frame with the same number are two different frames. The VESC frames on the Mini are extended, for example [`0x0901_vesc_status.yml`](../vehicles/ovcs_mini/priv/can/vesc/0x0901_vesc_status.yml); see [VESC drivetrain](./vesc_drivetrain.md#frames).

**Emitted frames** are sent every `frequency` ms by one `Cantastic.Emitter` process once your code configures and enables it. Their signals must be listed in bit order, contiguous from bit 0, and fill whole bytes, 64 bits at most. Gaps are filled with `static` signals. **Received frames** may describe only the bits you care about, and `frequency` is needed only if the frame is watched. A received frame shorter than its spec is dropped and logged; it does not crash the receiver.

### Watching for missing frames

A `Cantastic.ReceivedFrameWatcher` process exists per received frame, idle until you enable it. Once enabled, it checks the frame every `frequency` ms. A check is late when the last two receptions are more than `frequency + allowed_frequency_leeway` apart, or when nothing has arrived for ten times that. A watched frame starts out dead; once more than `required_on_time_frames` checks come out on time it becomes alive. Once more than `allowed_missing_frames` checks come out late, every subscriber gets one `{:handle_missing_frame, network, frame_name}` message and the frame is dead again until it recovers. The late-check count resets after 5 s without a late check.

Subscribe with `%{errors: true}` to receive those messages, then enable the watcher. From [`Vesc.MotorController`](../vms/core/lib/vms_core/components/vesc/motor_controller.ex):

```elixir
:ok = Receiver.subscribe(self(), network, [frames.status, frames.status_5], %{errors: true})
:ok = ReceivedFrameWatcher.enable(network, frames.status)
:ok = ReceivedFrameWatcher.enable(network, frames.status_5)
```

```elixir
def handle_info({:handle_missing_frame, network, name}, state)
    when network == state.network and name == state.frames.status do
  broadcast(state, :rotation_per_minute, nil, Units.revolution_per_minute())
  broadcast(state, :direction, nil, nil)
  broadcast(state, :motor_current, nil, Units.ampere())
  {:noreply, state}
end
```

Clear the values that frame carried, as here, so nothing downstream acts on stale data. `ReceivedFrameWatcher.is_alive?/2` returns `{:ok, boolean}` if you would rather poll; `OVCS.GenericController` does this for the controller's alive frame. Subscribing with errors to a frame without a `frequency` throws.

## Signals

A signal is a bit field plus the rule to turn it into a value.

| Key | Meaning | Default |
|---|---|---|
| `name` | The key your code reads and writes | required |
| `value_start` | Position of the first bit (see [Bit numbering](#bit-numbering-coming-from-dbc)) | required |
| `value_length` | Width in bits | required |
| `kind` | `decimal`, `integer`, `enum` or `static` | `decimal` |
| `sign` | `signed` or `unsigned` | `unsigned` |
| `endianness` | `little` or `big` | `little` |
| `scale`, `offset` | Decimal strings: `value = raw * scale + offset` | `"1"`, `"0"` |
| `precision` | Decimal places a `decimal` is rounded to | `2` |
| `mapping` | Raw value to value, for `enum` | |
| `value` | Raw value sent, for `static` | |
| `unit` | Informational | |

`decimal` values are `Decimal` structs, rounded to `precision`, so a fine `scale` needs a matching `precision`: [`set_duty_signals.yml`](../libraries/ovcs_can/priv/can/components/vesc/set_duty_signals.yml) pairs `scale: "0.00001"` with `precision: 5`. `integer` applies scale and offset, then rounds to an integer. Write `scale` and `offset` as quoted strings so YAML does not turn them into floats. On emit, Cantastic inverts the formula: `(value - offset) / scale`, rounded.

`enum` keys are the raw values (hex is fine); the values are what your code sees and sends, strings or booleans. A received raw value with no entry decodes to `nil`; emitting a value with no entry throws. [`0x600_gear_status.yml`](../libraries/ovcs_can/priv/can/components/ovcs/0x600_gear_status.yml) maps `0x00` to `drive`, so the emitter data carries `"selected_gear" => "drive"`.

`static` pads emitted frames. From [`0x280_engine_status.yml`](../libraries/ovcs_can/priv/can/components/volkswagen/polo_9n/0x280_engine_status.yml):

```yaml
- name: filler1
  kind: static
  value_start: 0
  value_length: 16
  value: 0x0000
```

Your code passes emitter data keyed by signal name. The OVCS1 reference vehicle's forwarder, for `0x60D_passenger_compartment_status.yml`:

```elixir
:ok =
  Emitter.configure(:ovcs, "passenger_compartment_status", %{
    parameters_builder_function: :default,
    initial_data: %{
      "front_left_door_open" => false,
      # ... one entry per non-static signal
    },
    enable: true
  })
```

On reception, each subscriber gets `{:handle_frame, %Cantastic.Frame{name: name, signals: signals}}`, where `signals` maps each name to a `%Cantastic.Signal{}` whose `value` is the decoded value.

## Bit numbering, coming from DBC

Cantastic has no DBC import or export. You translate by hand, and the bit numbering is not DBC's.

Cantastic reads the payload as one bit string in wire order: position 0 is the most significant bit of byte 0, position 7 its least significant bit, position 8 the most significant bit of byte 1. `value_start` cuts `value_length` bits starting at that position; only then is `endianness` applied, to the bits cut out, for `decimal` and `integer` signals (an `enum` matches the cut bits as they are). DBC numbers bits inside each byte from the least significant (bit 0) up. Between a DBC bit number `b` and a Cantastic position `p`:

```text
p = 8 * (b div 8) + 7 - (b mod 8)
```

What that means per layout:

- **Little-endian (Intel), byte-aligned, length a multiple of 8**: `value_start` is the DBC start bit, unchanged. This is the only case where the numbers agree, and most OVCS frames are in it. `rotations_per_minute` in `0x280_engine_status.yml` is `16|16@1+` in DBC and `value_start: 16` here.
- **Big-endian (Motorola)**: DBC's start bit is the signal's most significant bit, and so is `value_start`, converted with the formula. A byte-aligned Motorola signal starting in byte `n` has DBC start `8n + 7` and `value_start: 8n`.
- **Single-bit flags**: `value_start: 0` is DBC bit 7. The door flags in `0x60D_passenger_compartment_status.yml` sit at positions 0, 1, 2, … which are DBC bits 7, 6, 5, …
- **Little-endian, not byte-aligned**: see below.

### Worked example: a Motorola signal

`effective_torque` in the Nissan Leaf inverter's [`0x1DA_inverter_status.yml`](../libraries/ovcs_can/priv/can/components/nissan/leaf_aze0/0x1DA_inverter_status.yml):

```yaml
- name: effective_torque
  endianness: big
  sign: signed
  value_start: 21
  value_length: 11
  scale: "0.5"
  unit: N/m
```

Positions 21 to 31 are the low three bits of byte 2 and all of byte 3, most significant first. Position 21 is byte 2, bit 2 in DBC's per-byte numbering: DBC bit 18 (`8 * 2 + 7 - 2 = 21`). The equivalent DBC line is `SG_ effective_torque : 18|11@0- (0.5,0)`. For a payload `00 00 07 9C …`, the eleven bits are `111 1001 1100` = 0x79C = 1948, which is −100 as an 11-bit signed value, so `effective_torque` decodes to −50.00.

### Little-endian signals that are not byte-aligned

Little-endian decoding follows Erlang's binary rule: the leading whole bytes of the cut are the low bytes, and a trailing partial byte holds the most significant bits. A 12-bit little-endian field at `value_start: 0` takes its low byte from byte 0 and its top four bits from the *upper* nibble of byte 1. A DBC Intel `0|12@1+` keeps them in the *lower* nibble, so the two disagree. The generic controller's 12- and 14-bit fields (`0x7X3`, `0x7X4`) use the Cantastic layout, and the controller firmware packs them to match.

For an Intel signal that is not byte-aligned, give `value_start` a list of ranges, least significant first. Cantastic cuts each range and concatenates them with later ranges more significant. The iBooster's `rod_position` in [`0x39D_ibooster_status.yml`](../libraries/ovcs_can/priv/can/components/bosch/i_booster_gen2/0x39D_ibooster_status.yml):

```yaml
- name: rod_position
  endianness: big
  value_start:
    - start: 16
      length: 3
    - start: 24
      length: 8
    - start: 39
      length: 1
  value_length: 12
  scale: "0.015625"
```

That is DBC `21|12@1+`: the top three bits of byte 2 (DBC bits 21 to 23) are the low bits, byte 3 the middle, bit 0 of byte 4 (position 39) the top. `endianness: big` makes the concatenation read most significant first. `value_length` is still required and should equal the sum of the lengths. Range lists only work in received frames: an emitted frame's contiguity check rejects them.

## Imports and the shared specs

`import!:<path>` can replace any YAML value with the content of another file: an entry of a frame list, or the value of `signals`. Paths are relative to the directory of the importing file. `import!:@<otp_app>:<path>` resolves against that OTP application's `priv/` directory, which is how vehicles reach the shared specs:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

[`libraries/ovcs_can/priv/can/components/`](../libraries/ovcs_can/priv/can/components) is grouped by manufacturer (`bosch/`, `nissan/`, `orion/`, `volkswagen/`, `evpt/`, `vesc/`, `obd2/`) plus `ovcs/` for the framework's own frames. Complete frames carry their id in the filename (`0x1DA_inverter_status.yml`). Where the id depends on your vehicle, the library ships only the signal list, and your vehicle wraps it in a local frame file: `*_signals.yml` for the VESC, whose id carries the VESC's CAN id, and `generic_controller/0x7X1_alive_signals.yml` and siblings, where `X` is the controller id (see [Generic controllers](./generic_controllers.md#how-can-ids-are-derived)). The Mini's [`0x701_main_controller_alive.yml`](../vehicles/ovcs_mini/priv/can/generic_controller/0x701_main_controller_alive.yml):

```yaml
name: main_controller_alive
id: 0x701
frequency: 100
signals: import!:@ovcs_can:can/components/ovcs/generic_controller/0x7X1_alive_signals.yml
```

The Mini's `vms.yml` then imports these wrappers relatively (`import!:generic_controller/…`, `import!:vesc/…`) next to the shared frames it takes as they are. Frame files may also carry an `anchors` key for YAML anchors, as [`0x700_controller_configuration.yml`](../libraries/ovcs_can/priv/can/components/ovcs/0x700_controller_configuration.yml) does. If your vehicle uses a component the library does not describe, write its spec; if it is not specific to your vehicle, add it to `ovcs_can`.

## Mapping networks to interfaces

The YAML names networks; each side's composer says which interface carries each, per environment, in `default_can_mapping/1`. From the Mini's [VMS composer](../vehicles/ovcs_mini/lib/ovcs_mini/vms/composer.ex):

```elixir
def default_can_mapping(:host), do: "ovcs:vcan0,misc:vcan1"
def default_can_mapping(:target), do: "ovcs:spi0.0,misc:spi1.0"
```

`CAN_NETWORK_MAPPINGS`, when set at boot, replaces the mapping. A mapping that names a network absent from the YAML stops the boot. [Running on hardware](./running_hardware.md#can-interfaces) covers interface types and overrides, and [Your vehicle package](./vehicle_package.md) covers bridge mappings.

## Gatewaying between buses

Cantastic does not route frames between networks on its own. The OVCS1 reference vehicle republishes values from the VW Polo's original bus onto `ovcs` with [`Ovcs1.Vms.OVCSCANForwarder`](../vehicles/ovcs1/lib/ovcs1/vms/ovcs_can_forwarder.ex). Components on `polo_drive` decode their frames and broadcast the values on `OvcsBus`; the forwarder listens for door, beam, handbrake and speed messages from the configured source components and calls `Emitter.update/3` on `passenger_compartment_status` and `drivetrain_status`, which emit on `ovcs` at their own periods. The infotainment then reads framework frames only, whatever the donor car. For your vehicle, write the same kind of GenServer: subscribe to decoded values and write them into an `ovcs` emitter. `Cantastic.Emitter.forward/2` resends a received frame unchanged on another network whose YAML emits a frame of the same name, but nothing in the repository uses it.

## Next steps

- [Testing with CAN](./testing_with_can.md): inject and watch the frames you declared, on virtual CAN.
- [Generic controllers](./generic_controllers.md): the `0x7X*` frame family and controller ids.
- [VESC drivetrain](./vesc_drivetrain.md): extended-id frames wrapped around shared signal specs.
- [Cantastic README](https://github.com/open-vehicle-control-system/cantastic): the library's configuration options and the diagnostic codecs.
