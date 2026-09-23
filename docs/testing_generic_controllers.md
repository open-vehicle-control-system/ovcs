---
title: Generic controllers
description: Flash the generic controller firmware on an Arduino R4 Minima, adopt it from your application's VMS, and verify it on the bus.
---

A generic controller is an Arduino R4 Minima that lets the VMS switch relays, read digital and analog inputs, and drive PWM, DAC and external PWM outputs over CAN. It is generic because one firmware runs on every board: which pins do what is configured over CAN through an **adoption** process, and the board stores that configuration in EEPROM.

> [!NOTE]
> The controller firmware is part of the framework: the same binary runs on every board of every application. What each board does is decided by your application's VMS composer, which declares the boards and their pinouts in `generic_controllers/0`. The OVCS1 and OVCS Mini controllers below are worked examples.

Protocol details (frame layouts, pin numbering, status codes) are in [`controllers/generic_controller/README.md`](../controllers/generic_controller/README.md).

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

The board talks to the bus through an external MCP2517FD SPI CAN controller, not the R4 Minima's built-in CAN peripheral, so any Arduino-compatible board with EEPROM and that transceiver should work. On Linux, the upload needs a udev rule for the R4's USB ids; the controller README has it.

## How CAN ids are derived

The controller id is assigned during adoption and determines every frame id the board uses:

```text
Message ID = 0b111AAAABBBB
```

`AAAA` is the controller id, so up to 16 controllers fit on one network. `BBBB` is the frame number, up to 15 per controller; `0000` is reserved for the adoption frame `0x700`. So `0x7X1` means "frame 1 of controller X": controller 0 uses `0x701`–`0x70F`, controller 1 `0x711`–`0x71F`, and so on up to `0x7FF`.

| Frame | Direction | Content |
|---|---|---|
| `0x7X1` | controller → VMS | Alive and status, every 100 ms |
| `0x7X2` | VMS → controller | Digital output requests |
| `0x7X3` | VMS → controller | PWM and DAC requests |
| `0x7X4` | controller → VMS | Digital readbacks and analog inputs (14-bit), every 10 ms |
| `0x7X5`–`0x7X8` | VMS → controller | External PWM 0–3 (16-bit duty, 24-bit frequency) |
| `0x7X9` | controller → VMS | Pulse counter on A1: count and frequency, every 10 ms |

External PWM outputs live on a separate PWM hat that the Arduino drives over its UART (D0/D1); extra digital pins come from up to two MCP23008 expansion boards on I2C.

### Example: the reference applications

In the OVCS1 reference application the VMS composer declares three controllers:

| Controller | Frames | Purpose |
|---|---|---|
| `Vms.FrontController` (id 0) | `0x701`–`0x704` | High-voltage contactors, front sensors and relays |
| `Vms.RearController` (id 1) | `0x711`–`0x714` | Water pump, rear sensors and relays |
| `Vms.ControlsController` (id 2) | `0x721`–`0x725` | Steering column PWM, throttle pedal DAC, control inputs |

OVCS1's package also carries frame YAMLs for a test controller (id 3, `0x731`–`0x738`) that exercises every pin type. The OVCS Mini reference application declares one `Vms.MainController`: it drives the steering servo through external PWM and counts the spur gear's hall-effect sensor on A1. Your application can declare any number, up to 16 per network.

## Adopting a controller

You need:

- the controller flashed, and wired to the network your application maps to `ovcs`;
- the VMS running and reachable on that network, through the SPI CAN HAT on hardware, or through a USB CAN adapter from your laptop against `./ovcs run <app>`;
- the controller declared in the active application's `generic_controllers/0`, defined in `vehicles/<name>/lib/<name>/vms/composer/generic_controller.ex`.

### From the dashboard

1. Boot the VMS: `./ovcs run <app>`.
2. Open the dashboard (`http://localhost:5173`, the dev server `./ovcs run` starts) and go to the Generic Controllers page your composer declares.
3. Click **Adopt** next to the controller. The VMS broadcasts the configuration frame `0x700` for one second.
4. Within that second, press the adoption button on the Arduino (D2). The controller stores the configuration in EEPROM and moves from `ADOPTION_REQUIRED` to `READY`. Later boots load it automatically.

### From IEx

```elixir
VmsCore.Components.OVCS.GenericController.start_adoption(Ovcs1.Vms.FrontController)
# press the adoption button on the Arduino
VmsCore.Components.OVCS.GenericController.stop_adoption()
```

The atom passed to `start_adoption/1` must be a key of the active application's `generic_controllers/0` map; `Ovcs1.Vms.FrontController` is OVCS1's. To reconfigure a board, adopt it again: the new configuration overwrites the EEPROM.

## Verifying a controller

The examples use `can0`, a CAN adapter on the network the controller is on; use whichever interface carries `ovcs` for you.

### Alive frame

Byte 1 of `0x7X1` is the status code: `0x01` `ADOPTION_REQUIRED`, `0x02` `READY`, `0x03` `VMS_MISSING_ERROR`, `0x07` `EXPANSION_BOARDS_ERROR` (the full list is in the controller README).

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

Bytes 0–1 are the running count (16 bits, wrapping) and bytes 2–3 the frequency in tenths of a hertz, both little-endian. A wheel turned by hand should step the count and show a frequency that falls back to zero within two seconds of stopping. Edges closer than 2 ms are ignored as chatter. A1 is shared with analog input 0; when both are enabled, the pulse counter takes the pin.

> [!TIP]
> `./ovcs attach <app>` decodes these frames into named signals in its CAN pane, using your application's YAMLs. See the [CLI reference](../cli/README.md).

## OVCS Mini steering output

In the OVCS Mini reference application the steering servo is on PWM hat output 0 (`0x705`) at 100 Hz. Use the hat firmware with per-output prescaler selection and nearest-tick rounding: at 100 Hz it runs a /10 prescaler at 64 MHz, 0.15625 µs per tick, where a fixed /100 prescaler leaves the servo only coarse pulse steps. Updating the VMS alone doesn't change that hardware quantisation.

## Troubleshooting

### Controller stays in `ADOPTION_REQUIRED`

- Check that the VMS emits the configuration frame: `candump can0,700:7FF`.
- Press the adoption button **while** the configuration frame is broadcast, that is within a second of clicking Adopt or calling `start_adoption/1`.
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
