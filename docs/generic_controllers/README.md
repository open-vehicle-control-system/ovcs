---
title: Generic controllers
description: The one Arduino firmware every vehicle uses for relays, inputs and PWM, how frame ids and adoption work, how to flash, adopt and verify a board, and how your vehicle uses its pins.
---

A generic controller is an Arduino R4 Minima that lets the VMS switch relays, read digital and analog inputs, and drive PWM, DAC and external PWM outputs over CAN. It is generic because one firmware runs on every board: which pins do what is configured over CAN through an **adoption** process, and the board stores that configuration in EEPROM.

> [!NOTE]
> The controller firmware is part of the framework: the same binary runs on every board of every vehicle. What each board does is decided by your vehicle's VMS composer, which declares the boards and their pinouts in `generic_controllers/0`. The OVCS1 and OVCS Mini controllers below are worked examples.

Frame layouts and status codes are in the signal YAMLs under [`libraries/ovcs_can/priv/can/components/ovcs/generic_controller/`](../../libraries/ovcs_can/priv/can/components/ovcs/generic_controller/).

## What it does

| Pin type | Description | CAN frame |
|---|---|---|
| Digital output | On/off control for relays and contactors, on the board or on up to two MCP23008 expansion boards | `0x7X2` request / `0x7X4` status |
| Analog input | Sensor readings, 14-bit (0–16383) | `0x7X4` status |
| PWM output | Variable duty cycle, 12-bit (0–4095) | `0x7X3` request |
| DAC output | Analog voltage, 12-bit (0–4095) | `0x7X3` request |
| External PWM | PWM through a PWM hat on the Arduino's UART, 16-bit duty and 24-bit frequency | `0x7X5`–`0x7X8` request |
| Pulse counter | Rising edges on A1: count and frequency | `0x7X9` status |

A controller decides nothing on its own: it applies what the VMS requests and reports what it reads. It also guards the vehicle when the VMS goes away: if the VMS heartbeat stops, it shuts every output (see [The VMS heartbeat](#the-vms-heartbeat)).

## How it works

### How CAN ids are derived

The controller id is assigned during adoption and determines every frame id the board uses:

```text
Message ID = 0b111AAAABBBB
```

`AAAA` is the controller id, so up to 16 controllers fit on one network. `BBBB` is the frame number, up to 15 per controller; `0000` is reserved for the adoption frame `0x700`. So `0x7X1` means "frame 1 of controller X": controller 0 uses `0x701`–`0x709`, controller 1 `0x711`–`0x719`, up to controller 15 at `0x7F1`–`0x7F9`; frame numbers 10–15 are unused.

| Frame | Direction | Content |
|---|---|---|
| `0x7X1` | controller → VMS | Alive and status, every 100 ms |
| `0x7X2` | VMS → controller | Digital output requests |
| `0x7X3` | VMS → controller | PWM and DAC requests |
| `0x7X4` | controller → VMS | Digital readbacks and analog inputs (14-bit), every 10 ms |
| `0x7X5`–`0x7X8` | VMS → controller | External PWM 0–3 (16-bit duty, 24-bit frequency) |
| `0x7X9` | controller → VMS | Pulse counter on A1: count and frequency, every 10 ms |

External PWM outputs live on a separate PWM hat that the Arduino drives over its UART (D0/D1); extra digital pins come from up to two MCP23008 expansion boards on I2C.

### Adoption

1. A new, unconfigured controller joins the `ovcs` bus and broadcasts its status as `ADOPTION_REQUIRED`.
2. The VMS sends a configuration frame (`0x700`) with the pin assignments from your vehicle's `generic_controllers/0`, including the controller id.
3. You press the physical adoption button on the Arduino (D2) to confirm.
4. The controller stores the configuration in EEPROM, with a CRC32, and starts normal operation.
5. On later boots it loads the configuration from EEPROM and starts immediately. A configuration whose CRC does not match is rejected, and the controller asks for adoption again.

[Adopting a controller](#adopting-a-controller) walks through it from the dashboard or IEx.

### The VMS heartbeat

`VmsCore.Status` emits `vms_status` (`0x1A0`) every 100 ms. A controller that stops receiving it shuts every output and reports `VMS_MISSING_ERROR`; after power-up it gives the VMS 30 seconds before that counts. A VMS reboot always outlasts the timeout, so the VMS resets every controller once, three seconds after it boots, with the `reset_generic_controllers` command on `0x1AA`.

## Flashing the firmware

The firmware is a [PlatformIO](https://platformio.org/) project in `controllers/generic_controller/`, with three environments in `platformio.ini`:

| Environment | Purpose |
|---|---|
| `uno_r4_minima_prod` | Production build |
| `uno_r4_minima_debug` | Debug build with serial output |
| `local_test` | Unit tests (Unity framework), run on the host |

```sh
cd controllers/generic_controller
pio run -e uno_r4_minima_prod -t upload
```

### Bus bitrate

The firmware joins the bus at 500 kbps by default (`CAN_BITRATE` in [`lib/Can/Can.h`](../../controllers/generic_controller/lib/Can/Can.h)). It must match the bitrate your vehicle's `vms.yml` declares for the network the controller is wired to, or the controller never sees a frame. For another rate, pass it in bit/s as a build flag when you flash:

```sh
PLATFORMIO_BUILD_FLAGS="-D CAN_BITRATE=1000000" pio run -e uno_r4_minima_prod -t upload
```

As worked examples: the OVCS Mini reference vehicle's `ovcs` bus runs at the default 500 kbps; the OVCS1 reference vehicle's runs at 1 Mbps, so its controllers are flashed with `-D CAN_BITRATE=1000000`.

The board talks to the bus through an external MCP2517FD SPI CAN controller, not the R4 Minima's built-in CAN peripheral, so any Arduino-compatible board with EEPROM, an MCP2517FD controller and a CAN transceiver should work. On Linux, the upload needs a udev rule for the R4's USB ids; the controller README has it.

## Adopting a controller

You need:

- the controller flashed, and wired to the network your vehicle maps to `ovcs`;
- the VMS running and reachable on that network, through the SPI CAN HAT on hardware, or through a USB CAN adapter from your laptop against `./ovcs run <vehicle>` (start it with `CAN_NETWORK_MAPPINGS=ovcs:can0,…` so the VMS uses the adapter instead of `vcan0`);
- the controller declared in the active vehicle's `generic_controllers/0`, defined in `vehicles/<name>/lib/<name>/vms/composer/generic_controller.ex`.

### From the dashboard

1. Boot the VMS: `./ovcs run <vehicle>`.
2. Open the dashboard (`http://localhost:5173`, the dev server `./ovcs run` starts) and go to the Generic Controllers page your composer declares.
3. Click **Adopt** next to the controller. The VMS broadcasts the configuration frame `0x700` for one second.
4. Press the adoption button on the Arduino (D2), before or during that second: the controller shuts its outputs, waits for the next `0x700`, stores it in EEPROM and moves from `ADOPTION_REQUIRED` to `READY`. Pressing it on a running controller cuts its outputs until it is adopted again. Later boots load the configuration automatically.

### From IEx

```elixir
VmsCore.Components.OVCS.GenericController.start_adoption(Ovcs1.Vms.FrontController)
# press the adoption button on the Arduino
VmsCore.Components.OVCS.GenericController.stop_adoption()
```

The atom passed to `start_adoption/1` must be a key of the active vehicle's `generic_controllers/0` map; `Ovcs1.Vms.FrontController` is OVCS1's. To reconfigure a board, adopt it again: the new configuration overwrites the EEPROM.

## Verifying a controller

The examples use `can0`, a CAN adapter on the network the controller is on; use whichever interface carries `ovcs` for you.

### Alive frame

Byte 1 of `0x7X1` is the status code: `0x01` `ADOPTION_REQUIRED`, `0x02` `READY`, `0x03` `VMS_MISSING_ERROR`, `0x07` `EXPANSION_BOARDS_ERROR` (the full list is in [`0x7X1_alive_signals.yml`](../../libraries/ovcs_can/priv/can/components/ovcs/generic_controller/0x7X1_alive_signals.yml)). The firmware calls `0x02` `READY`, but that YAML decodes it as `OK`, so the dashboard and `./ovcs attach` show `OK`.

```sh
candump can0,701:7FF      # controller id 0
candump can0,711:7FF      # controller id 1
```

### Pin status

```sh
candump can0,704:7FF      # digital readbacks and analog inputs
```

### Pulse counter

```sh
candump can0,709:7FF
```

Bytes 0–1 are the running count (16 bits, wrapping) and bytes 2–3 the frequency in tenths of a hertz, both little-endian. A wheel turned by hand should step the count and show a frequency that falls back to zero within two seconds of stopping.

> [!TIP]
> `./ovcs attach <vehicle>` decodes these frames into named signals in its CAN pane, using your vehicle's YAMLs. See the [CLI reference](../../cli/README.md).

## Use it from your vehicle

Your VMS composer declares each board in `generic_controllers/0`, conventionally in `vehicles/<name>/lib/<name>/vms/composer/generic_controller.ex`: a process name per board and the pins it uses. It supervises one `OVCS.GenericController` per board (see [Drivers](../vms/drivers.md#framework-io-and-status)), and every component that drives or reads a pin is told which controller and which pin in its options: a relay, the throttle pedal's analog inputs, a servo on an external PWM. [Driving generic controller pins](../vms/add_a_component.md#driving-generic-controller-pins) shows how a component of your own does it.

### Example: the reference vehicles

In the OVCS1 reference vehicle the VMS composer declares three controllers:

| Controller | Frames | Purpose |
|---|---|---|
| `Vms.FrontController` (id 0) | `0x701`–`0x704` | High-voltage contactors, front sensors and relays |
| `Vms.RearController` (id 1) | `0x711`–`0x714` | Water pump, rear sensors and relays |
| `Vms.ControlsController` (id 2) | `0x721`–`0x725` | Steering column PWM, throttle pedal DAC, control inputs |

OVCS1's package also carries frame YAMLs for a test controller (id 3, `0x731`–`0x738`) that exercises every pin type. The OVCS Mini reference vehicle declares one `Vms.MainController`: it drives the steering servo through external PWM and counts the spur gear's hall-effect sensor on A1. Your vehicle can declare any number, up to 16 per network.

## Pin mapping

The OVCS pin number is what your composer's pinout and the frames use; the physical pin is the Arduino's.

### Reserved

| Physical pin | Use |
|---|---|
| D0  | UART receive |
| D1  | UART send |
| D2 | Adopt button |
| D3 | SPI CAN INT |
| D10 | SPI CAN CS |
| D11 | SPI CAN COPI |
| D12 | SPI CAN CIPO |
| D13 | SPI CAN SCK |
| A4 | I2C SDA - EXPANSION BOARDS |
| A5 | I2C SCL - EXPANSION BOARDS |

### Digital

| Physical pin | OVCS pin |
|---|---|
| D4  | 0 |
| D7  | 1 |
| D8  | 2 |
| EXPANSION_BOARD_0-0  | 3 |
| EXPANSION_BOARD_0-1  | 4 |
| EXPANSION_BOARD_0-2  | 5 |
| EXPANSION_BOARD_0-3  | 6 |
| EXPANSION_BOARD_0-4  | 7 |
| EXPANSION_BOARD_0-5  | 8 |
| EXPANSION_BOARD_0-6  | 9 |
| EXPANSION_BOARD_0-7  | 10 |
| EXPANSION_BOARD_1-0  | 11 |
| EXPANSION_BOARD_1-1  | 12 |
| EXPANSION_BOARD_1-2  | 13 |
| EXPANSION_BOARD_1-3  | 14 |
| EXPANSION_BOARD_1-4  | 15 |
| EXPANSION_BOARD_1-5  | 16 |
| EXPANSION_BOARD_1-6  | 17 |
| EXPANSION_BOARD_1-7  | 18 |

### PWM

| Physical pin | OVCS pin |
|---|---|
| D5  | 0 |
| D6  | 1 |
| D9  | 2 |

### DAC

| Physical pin | OVCS pin |
|---|---|
| A0  | 0 |

### Analog

| Physical pin | OVCS pin |
|---|---|
| A1  | 0 |
| A2  | 1 |
| A3  | 2 |

### Pulse counter input

| Physical pin | OVCS pin |
|---|---|
| A1  | 0 |

Rising edges on the pin are counted by interrupt, and the frame `0x7X9`
reports the running count (16 bits, wrapping) and the frequency in
tenths of a hertz every 10 ms, only while the pin is enabled. The
frequency is derived from the period between the last two edges, and
decays to zero once no edge has arrived for two seconds, so 0.5 Hz is
the slowest rate it reports. Edges closer than 2 ms are ignored as
chatter. A1 is shared with analog input 0; when both
are enabled in the adoption frame the pulse counter takes the pin.

## OVCS Mini steering output

In the OVCS Mini reference vehicle the steering servo is on PWM hat output 0 (`0x705`) at 100 Hz. Use the hat firmware with per-output prescaler selection and nearest-tick rounding: at 100 Hz it runs a /10 prescaler at 64 MHz, 0.15625 µs per tick, where a fixed /100 prescaler leaves the servo only coarse pulse steps. Updating the VMS alone doesn't change that hardware quantisation.

## Troubleshooting

### Controller stays in `ADOPTION_REQUIRED`

- Check that the VMS emits the configuration frame: `candump can0,700:7FF`.
- Press the adoption button **before or while** the configuration frame is broadcast, that is before the second after clicking Adopt or calling `start_adoption/1` ends. A press arms the controller until the next `0x700` arrives.
- Check the Arduino's USB serial output (`uno_r4_minima_debug` build) for parse errors.

### Controller goes to `VMS_MISSING_ERROR`

The controller expects the VMS status frame `0x1A0` every 100 ms after a boot grace period. Check:

- the VMS is running: `candump can0,1A0:7FF`;
- `CAN_NETWORK_MAPPINGS` (or the default mapping) routes `ovcs` to the interface the controller is on.

A VMS reboot, and so every redeploy, always trips this: the status frame stops for longer than the controller tolerates. The VMS resets the controllers itself three seconds after it boots, so the error clears once the new VMS is up. If a controller is still in this state afterwards, reset it as below.

### Controller goes to `EXPANSION_BOARDS_ERROR`

- I2C wiring: SDA on A4, SCL on A5.
- The MCP23008 expansion boards must be at addresses `0x20` and `0x21`.

### Resetting controllers from the VMS

```elixir
VmsCore.Status.trigger_action("reset_status", %{})
```

This emits the `reset_generic_controllers` command on `0x1AA` for one second, returning every controller to `READY`.
