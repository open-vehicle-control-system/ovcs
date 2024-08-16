# Generic Controller

This is a generic arduino controller allowing the VMS to actuate relays, read digital and analog inputs, activate PWM and DAC over the CAN network without having to program the arduino boards with a custom firwmare for each use case.

## Pin Mapping:

### Reserved

| Physical Pin | OVCS Usage |
| -------- | ------- |
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
| D0  | 0 |
| D1  | 1 |
| D4  | 2 |
| D7  | 3 |
| D8  | 4 |
| EXPANSION_BOARD_0-0  | 5 |
| EXPANSION_BOARD_0-1  | 6 |
| EXPANSION_BOARD_0-2  | 7 |
| EXPANSION_BOARD_0-3  | 8 |
| EXPANSION_BOARD_0-4  | 9 |
| EXPANSION_BOARD_0-5  | 10 |
| EXPANSION_BOARD_0-6  | 11 |
| EXPANSION_BOARD_0-7  | 12 |
| EXPANSION_BOARD_1-0  | 13 |
| EXPANSION_BOARD_1-1  | 14 |
| EXPANSION_BOARD_1-2  | 15 |
| EXPANSION_BOARD_1-3  | 16 |
| EXPANSION_BOARD_1-4  | 17 |
| EXPANSION_BOARD_1-5  | 18 |
| EXPANSION_BOARD_1-6  | 19 |
| EXPANSION_BOARD_1-7  | 20 |

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