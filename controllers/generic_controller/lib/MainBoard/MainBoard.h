#ifndef MAIN_BOARD_H
#define MAIN_BOARD_H

#include <AbstractBoard.h>

class MainBoard: public AbstractBoard {
  public:
    bool begin();
    void pinMode(uint8_t pin, uint8_t mode);
    void digitalWrite(uint8_t pin, uint8_t value);
    uint8_t digitalRead(uint8_t pin);
};

#endif