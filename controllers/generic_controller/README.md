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
| A4 | I2C SDA - MOSFET |
| A5 | I2C SCL - MOSFET |

### Digital

| Physical Pin | OVCS Pin |
| -------- | ------- |
| D0  | 0 |
| D1  | 1 |
| D4  | 2 |
| D7  | 3 |
| D8  | 4 |
| MOSFET0-0  | 5 |
| MOSFET0-1  | 6 |
| MOSFET0-2  | 7 |
| MOSFET0-3  | 8 |
| MOSFET0-4  | 9 |
| MOSFET0-5  | 10 |
| MOSFET0-6  | 11 |
| MOSFET0-7  | 12 |
| MOSFET1-0  | 13 |
| MOSFET1-1  | 14 |
| MOSFET1-2  | 15 |
| MOSFET1-3  | 16 |
| MOSFET1-4  | 17 |
| MOSFET1-5  | 18 |
| MOSFET1-6  | 19 |
| MOSFET1-7  | 20 |

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