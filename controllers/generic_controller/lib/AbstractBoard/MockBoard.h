#ifndef MOCK_BOARD_H
#define MOCK_BOARD_H

#include <AbstractBoard.h>

class MockBoard: public AbstractBoard {
  public:
    MockBoard(){};
    MockBoard(uint8_t address){};
    bool begin();
    void pinMode(uint8_t pin, PinMode mode);
    void digitalWrite(uint8_t pin, PinStatus status);
    PinStatus digitalRead(uint8_t pin);
};

#endif