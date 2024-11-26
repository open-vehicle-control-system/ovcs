#ifndef EXPANSION_BOARD_H
#define EXPANSION_BOARD_H

#include <AbstractBoard.h>
#include <MCP23008.h>

class ExpansionBoard: public AbstractBoard {
  public:

    ExpansionBoard(uint8_t address){
      _board = MCP23008(address);
    };

    bool begin();
    uint8_t lastError();
    void pinMode(uint8_t pin, PinMode mode);
    void digitalWrite(uint8_t pin, PinStatus status);
    PinStatus digitalRead(uint8_t pin);

  private:
    MCP23008 _board = MCP23008(0x20); // TODO Why is this required?
};

#endif