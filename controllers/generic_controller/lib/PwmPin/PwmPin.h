#ifndef PWM_PIN_H
#define PWM_PIN_H

#include <OtherPin.h>

class PwmPin: public OtherPin {
  public:
    PwmPin() {};
    PwmPin(bool enabled, uint8_t physicalPin) : OtherPin(enabled, physicalPin) {
      pinMode(physicalPin, OUTPUT);
    };
    bool writeable();
    void writeIfAllowed(uint16_t dutyCycle);
};

#endif