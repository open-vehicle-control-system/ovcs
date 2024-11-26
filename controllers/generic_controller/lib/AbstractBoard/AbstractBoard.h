#ifndef ABSTRACT_BOARD_H
#define ABSTRACT_BOARD_H

#ifdef LOCAL_TEST
  #include <TestTypes.h>
#endif

#include <Arduino.h>

class AbstractBoard {

  public:
    AbstractBoard(){};
    AbstractBoard(uint8_t address){};
    virtual bool begin() = 0;
    virtual uint8_t lastError() = 0;
    virtual void pinMode(uint8_t pin, PinMode mode) = 0;
    virtual void digitalWrite(uint8_t pin, PinStatus status) = 0;
    virtual PinStatus digitalRead(uint8_t pin) = 0;
};

#endif