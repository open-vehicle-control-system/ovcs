# Generic Controller

This is a generic arduino controller.

## Lifecycle

- VMS start controller initialization process by sending the following frame every 100ms:
  - 0x700 |  6 bit controller id | ...
- Controller is adopting the id when user is pushing button on digital pin D2


## Pins

- 2x I2C module  8 out (digital) (hardware adress 3 bits)
- 6 analog inputs
- 14 digital I/O

## Available Pins

Since SPI is using for the CAN module and I2C for the MOSFET modules and 1 digital pin is used for the adoption button, we have the following pins to be configured:

- Digital, 24 pins:
  - 8 Pin on the Arduino itself: D0, D1, D4, D5, D6, D7, D8, D9
  - 8 Pin on the Mosfet 1
  - 8 Pin on the Mosfet 2
- Analog,
  - 4 pins on the Arduino itself
### Digital pin configuration

- The 24 digital pins must be be configured as off (00),  read-only (01) or write-only (10) read-write(11)
  - 6 bytes: 11 11 11 11 11 11 11 11 11 11 11
- D5, D6 and D9 could also be used as output PWM (By default, the resolution is 8 bit (0-255), You can use analogWriteResolution() to change this, supporting up to 12 bit (0-4096) resolution)

- The 4 analog pins must be configured as active (1) or not
  - 4 bits 1111
- A0 could be used as an output DAC (with a default resolution of 8 bits, up to 12 bits)




1 message de status avec les 21 digital + 3 analog

1 message de write digital
1 message de write PWM + DAC