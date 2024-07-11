#ifndef PWM_PIN_H
#define PWM_PIN_H

#include <other_pin.h>

class PwmPin: public OtherPin {
  public:
    PwmPin() {};
    PwmPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {
      pinMode(initialPhysicalPin, OUTPUT);
    };
    bool writeable();
    void writeIfAllowed(uint16_t dutyCycle);
};

#endif