# Testing Generic Controllers

OVCS uses Arduino R4 Minima boards as configurable I/O controllers. A single
firmware runs on every board; each board is told which pins to use over CAN
through an **adoption** process. This guide covers adoption and how to verify
a controller is healthy.

For the protocol details (CAN-ID derivation, pin numbering, status codes),
see [`controllers/generic_controller/README.md`](../controllers/generic_controller/README.md).

## Prerequisites

- The Arduino R4 Minima is flashed with the generic controller firmware
  (`./ovcs build` … or PlatformIO directly — see
  [`docs/running_hardware.md`](./running_hardware.md)).
- The VMS is reachable on the OVCS CAN bus, either:
  - Locally, on `vcan0` provisioned by `./ovcs can setup <vehicle>`.
  - On hardware via the SPI-CAN HAT.
- The active vehicle's VMS composer declares the controller you want to
  adopt in `generic_controllers/0` (e.g. `Vms.FrontController` for OVCS1).

## Adopting a controller

Adoption can be triggered from the **dashboard** or from **IEx**.

### From the dashboard

1. Boot the VMS — `./ovcs run <vehicle>` from the repo root, or
   `cd vms/api && VEHICLE=Ovcs1 mix phx.server`.
2. Open the Vue dashboard (`cd vms/dashboard && npm run dev`,
   `http://localhost:5173`) and navigate to the Generic Controllers page.
3. Click **Adopt** next to the controller you want to configure.
4. Within ~1 second, press the physical adoption button on the Arduino (D2).
5. The controller stores the configuration in EEPROM and transitions from
   `ADOPTION_REQUIRED` to `READY`. Subsequent boots load the configuration
   automatically.

### From IEx

```elixir
VmsCore.Components.OVCS.GenericController.start_adoption(Ovcs1.Vms.FrontController)
# press the adoption button on the Arduino
VmsCore.Components.OVCS.GenericController.stop_adoption()
```

The atom passed to `start_adoption/1` must be a key in the active vehicle
composer's `generic_controllers/0` map (see
`vehicles/<name>/lib/<name>/vms/composer/generic_controller.ex`).

## Verifying a controller

### Confirm the alive frame is on the bus

Each adopted controller emits an alive frame at `0x7X1` (`X` = controller
ID) every 100 ms. Snoop it with `candump`:

```sh
candump can0,701:7FF      # FrontController on OVCS1 (controller_id 0)
candump can0,711:7FF      # RearController (controller_id 1)
candump can0,721:7FF      # ControlsController (controller_id 2)
```

Byte 1 of the frame is the status code. `0x02` = `READY`.

### Pin status

Digital readbacks and analog inputs are reported on `0x7X4` every 10 ms:

```sh
candump can0,704:7FF
```

A controller with its pulse counter enabled also reports the count and
frequency of the edges on A1 on `0x7X9`, every 10 ms:

```sh
candump can0,709:7FF
```

Bytes 0-1 are the count and bytes 2-3 the frequency in tenths of a
hertz, both little-endian. A wheel turned by hand should step the count
and show a frequency that falls back to zero within two seconds of
stopping.

The frame layouts are in
[`controllers/generic_controller/README.md`](../controllers/generic_controller/README.md).

## OVCS Mini throttle resolution and calibration

The throttle path is radio channel 2 on CAN `0x2A0`, VMS
`Traxxas.Throttle`, CAN `0x706`, Arduino UART, then HAT output 1 (RB3)
to the ESC. The Arduino forwards the 16-bit duty unchanged. Full scale
is 65535 on both ends, and the output frequency is 100 Hz.

Use the HAT firmware with per-output prescaler selection and nearest-tick
rounding. At 100 Hz it uses a /10 prescaler at 64 MHz: 64000 timer ticks
per period, or 0.15625 us per tick. A fixed /100 prescaler leaves only
about 27 distinct pulses in the Mini's 1510-1550 us forward modulation
range. Updating only the VMS does not fix that hardware quantisation.

The Mini composer sets 5% input deadzone, 0.5 expo, 0.02 start offset,
0.1 forward cap and 0.2 reverse/brake cap. For forward requests outside
the deadzone:

```text
request = (radio_channel_2 - 1500) / 500
x = (request - 0.05) / 0.95
throttle = 0.02 + 0.08 * (0.5*x + 0.5*x*x)
pulse_us = 1500 + 500*throttle
```

The **Radio Control** page shows both the input request and the commanded
throttle/pulse after the curve. The latter is before CAN/timer quantisation,
not a measured HAT or ESC readback. The first VMS tick commands neutral,
even if no source has been selected yet.

After deploying the VMS and flashing the HAT, verify the pulse on RB3 with
the ESC disconnected from the signal. A period is 10 ms; expected widths
are 1500 us at neutral, approximately 1510 us just beyond the forward
deadzone, 1525 us at request 0.525, 1550 us at full forward and 1400 us
at full reverse/brake. Allow for oscillator accuracy and sub-microsecond
CAN/timer rounding. Check the steering output too after flashing the HAT.

With the drivetrain secured and wheels clear, reconnect the ESC and sweep
the trigger slowly up and down. Record **Commanded ESC Pulse** when the
wheels start and when they stop; repeat under a controlled rolling load.
The start threshold can differ from the stop threshold. The initial offset
is conservative, not a measured calibration. A measured forward threshold
can be expressed as `(pulse_us - 1500) / 500`, but do not raise the offset
above the minimum sustainable command merely to force a quicker start:
that creates a jump and spends the available modulation range.

Check which endpoints the ESC learned. Its calibration must use the full
1000/1500/2000 us actuator range, following the exact ESC model's procedure,
with propulsion mechanically isolated. Do not calibrate it using the
normal capped Mini curve: teaching 1550 us as full forward defeats the cap.
Return to normal capped operation before any driving test.

The speed sensor is available for observing the result, but the throttle
path is open loop: a 10% throttle cap is not a 10% speed guarantee. If the
lowest stable motor speed is still too high after the waveform and ESC
calibration are verified, further changes need measured drivetrain behavior;
an uncalibrated speed controller or a larger start offset is not a substitute.

## Troubleshooting

### Controller stays in `ADOPTION_REQUIRED`

- Confirm the VMS is emitting the configuration frame: `candump can0,700:7FF`.
- Press the adoption button **after** clicking Adopt / calling
  `start_adoption/1` — the configuration frame is broadcast for ~1 second.
- Check the Arduino's USB serial output for parse errors.

### Controller goes to `VMS_MISSING_ERROR`

The controller expects the VMS heartbeat (`0x1A0`) every 100 ms after a
boot grace period. Confirm:

- The VMS is running: `candump can0,1A0:7FF`.
- `CAN_NETWORK_MAPPINGS` routes `ovcs:` to the same interface the
  controller is on.

A VMS reboot, and therefore every redeploy, always trips this: the
heartbeat stops for longer than the controller tolerates. The VMS
resets the controllers itself three seconds after it boots, so the
error clears on its own once the new VMS is up. If a controller is
still in this state afterwards, use the reset below.

### Controller goes to `EXPANSION_BOARDS_ERROR`

- I2C wiring: SDA on A4, SCL on A5.
- MCP23008 expansion boards must be at addresses `0x20` and `0x21`.

### Resetting controllers from the VMS

```elixir
VmsCore.Status.trigger_action("reset_status", %{})
```

This emits `reset_generic_controllers` (`0x1AA`) for one second, returning
all controllers to `READY`.

### Re-adopting

Run adoption again with a different `controller_name`. The new
configuration overwrites the previous EEPROM data.

Next: [Hardware Architecture](./hardware_architecture.md)
