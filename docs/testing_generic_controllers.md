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

The frame layout is in
[`controllers/generic_controller/README.md`](../controllers/generic_controller/README.md).

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
