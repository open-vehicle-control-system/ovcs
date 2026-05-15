# Generic Controller

A generic Arduino controller that lets the VMS actuate relays, read digital and analog inputs, and drive PWM / DAC over the CAN network — without having to program each board with a use-case-specific firmware. Targets the Arduino R4 Minima.

For adoption and verification from the VMS side, see
[`docs/testing_generic_controllers.md`](../../docs/testing_generic_controllers.md).
For where each OVCS1 controller fits on the bus and which pin types it
uses, see [`docs/hardware_architecture.md`](../../docs/hardware_architecture.md#generic-controllers).

## Flashing

Build / upload via PlatformIO:

```sh
pio run -e uno_r4_minima_prod -t upload
```

### Linux: USB permissions for the R4

Without a udev rule, `dfu-util` fails with `LIBUSB_ERROR_ACCESS` (`Cannot open DFU device 2341:0069`). Add the rule once per host:

```sh
sudo tee /etc/udev/rules.d/60-arduino-uno-r4.rules >/dev/null <<'EOF'
# Arduino UNO R4 Minima / WiFi — run mode
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0069", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1002", MODE="0666"
# DFU bootloader mode
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0369", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1102", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug + replug the board afterwards. Double-tap the reset button if the upload doesn't drop the board into DFU automatically.

## Controller ID

Controller ID is defined during adoption and used to derive the CAN message IDS:

`Message ID = 0b111AAAABBBB`

Where

* `AAAA` represents the controller id bits, meaning that we can have up to 16 controllers on one CAN network
* `BBBB` represents the message ID itself, allowing up to 15 messages per controller (emitted or received), 000 is reserved for the adoption frame.

### Controller/Frame ID 4 bits binary mapping

| Decimal | Binary |
|---------|--------|
|0        |    0000|
|1        |    0001|
|2        |    0010|
|3        |    0011|
|4        |    0100|
|5        |    0101|
|6        |    0110|
|7        |    0111|
|8        |    1000|
|9        |    1001|
|10       |    1010|
|11       |    1011|
|12       |    1100|
|13       |    1101|
|14       |    1110|
|15       |    1111|

## Example Frame IDS

| Controller ID | Frame number | Frame ID Binary    | Frame ID HEX |
|---------------|--------------|--------------------|--------------|
| 0             | 1            | 0b0000011100000001 | 0x701        |
| 0             | 15           | 0b0000011100001111 | 0x70F        |
| 1             | 1            | 0b0000011100010001 | 0x711        |
| 1             | 15           | 0b0000011100011111 | 0x71F        |
| 2             | 1            | 0b0000011100100001 | 0x721        |
| 2             | 15           | 0b0000011100101111 | 0x72F        |
| ...           | ...          | ...                | ...          |
| 15            | 1            | 0b0000011111110001 | 0x7F1        |
| 15            | 15           | 0b0000011111111111 | 0x7FF        |

## Pin Mapping

### Reserved

| Physical Pin | OVCS Usage |
| -------- | ------- |
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

| Physical Pin | OVCS Pin |
| -------- | ------- |
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

| Physical Pin | OVCS Pin |
| -------- | ------- |
| D5  | 0 |
| D6  | 1 |
| D9  | 2 |

### DAC

| Physical Pin | OVCS Pin |
| -------- | ------- |
| A0  | 0 |

### Analog

| Physical Pin | OVCS Pin |
| -------- | ------- |
| A1  | 0 |
| A2  | 1 |
| A3  | 2 |
