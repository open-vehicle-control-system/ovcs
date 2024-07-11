#ifndef ANALOG_PIN_H
#define ANALOG_PIN_H

#include <OtherPin.h>

class AnalogPin: public OtherPin {
  public:
    AnalogPin() {};
    AnalogPin(bool enabled, uint8_t physicalPin) : OtherPin(enabled, physicalPin) {};
    bool readable();
    uint8_t readIfAllowed();
};

#endif