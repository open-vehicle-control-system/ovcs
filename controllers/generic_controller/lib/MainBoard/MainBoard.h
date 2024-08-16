#ifndef MAIN_BOARD_H
#define MAIN_BOARD_H

#include <AbstractBoard.h>

class MainBoard: public AbstractBoard {
  public:
    bool begin();
    void pinMode(uint8_t pin, PinMode mode);
    void digitalWrite(uint8_t pin, PinStatus status);
    PinStatus digitalRead(uint8_t pin);
};

#endif