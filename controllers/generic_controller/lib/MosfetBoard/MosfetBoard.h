#ifndef MOSFET_BOARD_H
#define MOSFET_BOARD_H

#include <AbstractBoard.h>
#include <MCP23008.h>
#define I2C_CLOCK_FREQUENCY 100000

class MosfetBoard: public AbstractBoard {
  public:

    MosfetBoard(uint8_t address){
      board = MCP23008(address);
      _address = address;
    };

    bool begin();
    void pinMode(uint8_t pin, uint8_t mode);
    void digitalWrite(uint8_t pin, uint8_t value);
    uint8_t digitalRead(uint8_t pin);

  private:
    MCP23008 board = MCP23008(0x20); // TODO Why is this required?
    uint8_t _address;

};

#endif