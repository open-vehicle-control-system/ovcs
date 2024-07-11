#ifndef ANALOG_PIN_H
#define ANALOG_PIN_H

#include <OtherPin.h>

class AnalogPin: public OtherPin {
  public:
    AnalogPin() {};
    AnalogPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {};
    bool readable();
    uint8_t read();
};

#endif