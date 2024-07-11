#ifndef DAC_PIN_H
#define DAC_PIN_H

#include <OtherPin.h>

class DacPin: public OtherPin {
  public:
    DacPin() {};
    DacPin(bool enabled, uint8_t physicalPin) : OtherPin(enabled, physicalPin) {
      pinMode(physicalPin, OUTPUT);
    };

    bool writeable();
    void writeIfAllowed(uint16_t value);
};

#endif