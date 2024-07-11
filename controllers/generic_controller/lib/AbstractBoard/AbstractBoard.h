#ifndef ABSTRACT_BOARD_H
#define ABSTRACT_BOARD_H

#include <Arduino.h>

class AbstractBoard {

  public:
    AbstractBoard(){};
    AbstractBoard(uint8_t address){};
    virtual bool begin();
    virtual void pinMode(uint8_t pin, uint8_t mode);
    virtual void digitalWrite(uint8_t pin, uint8_t value);
    virtual uint8_t digitalRead(uint8_t pin);
};

#endif