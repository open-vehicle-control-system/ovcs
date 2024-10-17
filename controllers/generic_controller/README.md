# Generic Controller

This is a generic arduino controller allowing the VMS to actuate relays, read digital and analog inputs, activate PWM and DAC over the CAN network without having to program the arduino boards with a custom firwmare for each use case.

## Controller ID

Controller ID is defined during adoption and used to derive the CAN message IDS:

`Message ID = 0b00000111AAAAABBB`

Where

* `AAAAA` represents the controller id bits, meaning that we can have up to 32 controllers on one CAN network
* `BBB` represents the message ID itself, allowing up to 7 messages per controller (emitted or received), 000 is reserved for the adoption frame.

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