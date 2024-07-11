#ifndef OTHER_PIN_H
#define OTHER_PIN_H

#include <Arduino.h>

class OtherPin {
  public:
    OtherPin() {};
    OtherPin(bool enabled, uint8_t physicalPin) {
      _enabled     = enabled;
      _physicalPin = physicalPin;
    };

  protected :
    bool  _enabled;
    uint8_t _physicalPin;
};

#endif