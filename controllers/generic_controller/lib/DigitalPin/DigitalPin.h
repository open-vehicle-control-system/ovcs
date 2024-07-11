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
    DigitalPin(uint8_t initialStatus, AbstractBoard* initialBoard, uint8_t initialPhysicalPin) {
      status      = initialStatus;
      board       = initialBoard;
      physicalPin = initialPhysicalPin;
      initPhysicalPin();
    };
    void writeIfAllowed(bool value) ;
    uint8_t readIfAllowed();
    bool writeable();
    bool readable();

  private:
    uint8_t status;
    AbstractBoard* board;
    uint8_t physicalPin;

    void initPhysicalPin();

};

#endif