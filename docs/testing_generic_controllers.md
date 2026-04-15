# Testing Generic Controllers

This guide covers how to test OVCS generic controllers (Arduino R4 Minima boards) using the built-in `TestController` configuration. The TestController has all pin types enabled, making it suitable for verifying hardware wiring, I/O expansion boards, and CAN communication.

## Overview

The generic controller system uses a single firmware for all Arduino boards. Each board receives its identity and pin configuration through an **adoption** process over CAN bus. For testing purposes, OVCS1 defines a dedicated `TestController` (controller ID 3, CAN ID range `0x73x`) with all 19 digital pins, 3 PWM pins, 1 DAC pin, 3 analog inputs, and 4 external PWM channels enabled.

The `VmsCore.Controllers.TestController` module provides convenience functions to toggle outputs and read inputs without writing custom code.

## Prerequisites

- A Linux machine with SocketCAN support (or the VMS Raspberry Pi itself)
- A physical or virtual CAN interface
- An Arduino R4 Minima flashed with the generic controller firmware (see [Running on Hardware](./running_hardware.md))
- VMS Core and API dependencies compiled

## Step-by-Step Testing

### 1. Set Up CAN Interfaces

Start the physical CAN interface for the OVCS bus and virtual CAN interfaces for the remaining buses:

```sh
./scripts/setup_can.sh          # physical can0 for the OVCS bus
./ovcs can setup ovcs1          # virtual vcan1..vcan4 for leaf_drive, polo_drive, orion_bms, misc
```

### 2. Start the VMS

Start the VMS API with CAN network mappings that route the OVCS bus to the physical interface and the rest to virtual interfaces:

```sh
cd vms/api
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 iex -S mix phx.server
```

The VMS will start emitting status heartbeats on `can0` and listening for controller alive frames.

### 3. Adopt the Test Controller

From the IEx session, initiate adoption for the `test_controller` configuration:

```elixir
VmsCore.Controllers.Configuration.start_adoption("test_controller")
```

This sends the configuration frame (CAN ID `0x700`) containing:
- Controller ID: 3
- All 19 digital pins set to `read_write`
- All PWM, DAC, and analog pins enabled
- All 4 external PWM channels enabled

The frame is emitted at 100ms intervals for approximately 1 second.

### 4. Confirm Adoption on the Arduino

**Press the physical adoption button** (wired to pin D2) on the Arduino board.

The controller will:
1. Receive the configuration frame from the OVCS CAN bus
2. Store the 8-byte configuration in EEPROM with a CRC32 checksum
3. Parse the configuration to compute its CAN frame IDs (`0x731`-`0x738`)
4. Initialize all pins according to their configured modes
5. Transition from `ADOPTION_REQUIRED` to `READY` status

If USB serial is connected, the adopted configuration is printed to the serial output for verification.

> **Note:** Once adopted, the configuration persists in EEPROM. The controller will load it automatically on subsequent boots without re-adoption.

### 5. Verify the Controller Is Online

After adoption, the controller emits an alive frame (`0x731`) every 100ms. You can verify it is online by monitoring the CAN bus:

```sh
candump can0,731:7FF
```

You should see periodic frames with status byte `0x02` (READY).

### 6. Test Digital I/O

#### Enable All Digital Pins

Turn on all 19 digital outputs (3 on the main board + 8 on each expansion board):

```elixir
VmsCore.Controllers.TestController.on()
```

#### Disable All Digital Pins

Turn off all 19 digital outputs:

```elixir
VmsCore.Controllers.TestController.off()
```

#### Control a Specific Pin

Enable or disable a single digital pin by its OVCS pin number (0-18):

```elixir
# Turn on pin 5 (expansion board 1, physical pin 2)
VmsCore.Controllers.TestController.on(5)

# Turn off pin 5
VmsCore.Controllers.TestController.off(5)
```

**Digital pin mapping reference:**

| OVCS Pin | Location | Physical Pin |
|----------|----------|-------------|
| 0 | Main board | D4 |
| 1 | Main board | D7 |
| 2 | Main board | D8 |
| 3-10 | Expansion board 1 (I2C `0x20`) | MCP23008 pins 0-7 |
| 11-18 | Expansion board 2 (I2C `0x21`) | MCP23008 pins 0-7 |

### 7. Monitor Pin Status

The controller reports its actual pin states back to the VMS via the digital and analog pin status frame (`0x734`) every 10ms. Monitor this from the CAN bus:

```sh
candump can0,734:7FF
```

This frame contains:
- 19 digital pin readback values (1 bit each)
- 3 analog input readings (14-bit each, 0-16383)

## CAN Frame Reference (TestController)

| CAN ID | Frame Name | Direction | Frequency | Content |
|--------|-----------|-----------|-----------|---------|
| `0x700` | controller_configuration | VMS -> Arduino | 100ms (during adoption) | Controller ID, pin mode configuration |
| `0x731` | test_controller_alive | Arduino -> VMS | 100ms | Counter, status, expansion board errors |
| `0x732` | test_controller_digital_pin_request | VMS -> Arduino | 10ms | 19 digital pin on/off states |
| `0x733` | test_controller_other_pin_request | VMS -> Arduino | 10ms | 3 PWM + 1 DAC duty cycles (12-bit) |
| `0x734` | test_controller_digital_and_analog_pin_status | Arduino -> VMS | 10ms | 19 digital readbacks + 3 analog values |
| `0x735` | test_controller_external_pwm0_request | VMS -> Arduino | 10ms | Enabled, duty cycle (16-bit), frequency |
| `0x736` | test_controller_external_pwm1_request | VMS -> Arduino | 10ms | Enabled, duty cycle (16-bit), frequency |
| `0x737` | test_controller_external_pwm2_request | VMS -> Arduino | 10ms | Enabled, duty cycle (16-bit), frequency |
| `0x738` | test_controller_external_pwm3_request | VMS -> Arduino | 10ms | Enabled, duty cycle (16-bit), frequency |

## Controller Status Codes

Monitor the status byte in the alive frame (`0x731`, byte 1) to diagnose issues:

| Value | Status | Meaning |
|-------|--------|---------|
| 0 | `STARTING` | Controller is booting |
| 1 | `ADOPTION_REQUIRED` | No valid configuration in EEPROM |
| 2 | `OK` / `READY` | Normal operation |
| 3 | `VMS_MISSING_ERROR` | No VMS heartbeat received (after 30s boot grace period) |
| 4 | `VMS_LATENCY_ERROR` | VMS heartbeats arriving too late |
| 5 | `VMS_COUNTER_MISMATCH_ERROR` | VMS heartbeat counter not incrementing correctly |
| 6 | `VMS_FAILURE_ERROR` | VMS reports failure status |
| 7 | `EXPANSION_BOARDS_ERROR` | I2C communication error with MCP23008 expansion boards |

## Troubleshooting

### Controller stays in `ADOPTION_REQUIRED`

- Ensure the VMS is emitting the configuration frame: `candump can0,700:7FF`
- Press the adoption button **after** calling `start_adoption/1`
- Check USB serial output for error messages

### Controller goes to `VMS_MISSING_ERROR`

The controller expects VMS status frames (`0x1A0`) every 100ms after a 30-second boot grace period. Ensure the VMS is running and emitting on the correct CAN interface.

### Controller goes to `EXPANSION_BOARDS_ERROR`

- Check I2C wiring to the MCP23008 expansion boards (SDA on A4, SCL on A5)
- Verify expansion board addresses (`0x20` and `0x21`)
- The controller retries I2C operations up to 4 times before entering error state

### Recovering from Error States

If a controller enters an error state, you can reset it from the VMS:

```elixir
VmsCore.Status.trigger_action("reset_status", %{})
```

This sends a `reset_generic_controllers` command (`0x1AA`) for 1 second, which transitions all controllers back to `READY` state.

### Re-adopting a Controller

To change a controller's configuration, simply call `start_adoption/1` again with the new configuration name and press the adoption button. The new configuration overwrites the previous EEPROM data.

## Testing on the Dashboard

If the VMS dashboard is accessible (typically at `http://<vms-ip>:4000`), the generic controllers page provides:
- Real-time status and pin values for each controller
- An **Adopt** button to trigger adoption from the UI
- Visual indicators for controller health and expansion board errors

Next: [Hardware Architecture](./hardware_architecture.md)
