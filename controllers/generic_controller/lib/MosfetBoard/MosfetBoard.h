#ifndef MOSFET_BOARD_H
#define MOSFET_BOARD_H

#include <AbstractBoard.h>
#include <MCP23008.h>
#define I2C_CLOCK_FREQUENCY 100000

class MosfetBoard: public AbstractBoard {
  public:

    MosfetBoard(uint8_t address){
      _board = MCP23008(address);
    };

    bool begin();
    void pinMode(uint8_t pin, PinMode mode);
    void digitalWrite(uint8_t pin, PinStatus status);
    uint8_t digitalRead(uint8_t pin);

  private:
    MCP23008 _board = MCP23008(0x20); // TODO Why is this required?
};

#endif