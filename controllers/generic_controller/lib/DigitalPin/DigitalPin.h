#ifndef DIGITAL_PIN_H
#define DIGITAL_PIN_H

#include <Arduino.h>
#include <AbstractBoard.h>

#define DIGITAL_PIN_DISABLED 0
#define DIGITAL_PIN_READ_ONLY 1
#define DIGITAL_PIN_WRITE_ONLY 2
#define DIGITAL_PIN_READ_WRITE 3

class DigitalPin {
  public:
    DigitalPin() {};
    DigitalPin(uint8_t status, AbstractBoard* board, uint8_t physicalPin) {
      _status      = status;
      _board       = board;
      _physicalPin = physicalPin;
      initPhysicalPin();
    };
    void writeIfAllowed(bool value) ;
    uint8_t readIfAllowed();
    bool writeable();
    bool readable();

  private:
    uint8_t _status;
    AbstractBoard* _board;
    uint8_t _physicalPin;

    void initPhysicalPin();
};

#endif