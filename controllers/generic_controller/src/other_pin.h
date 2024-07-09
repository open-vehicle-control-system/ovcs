#ifndef OTHER_PIN_H
#define OTHER_PIN_H

#include <Arduino.h>

class OtherPin {
  public:
    OtherPin() {};
    OtherPin(bool initialEnabled, uint8_t initialPhysicalPin) {
      enabled     = initialEnabled;
      physicalPin = initialPhysicalPin;
    };

  protected :
    bool  enabled;
    uint8_t physicalPin;
};

#endif