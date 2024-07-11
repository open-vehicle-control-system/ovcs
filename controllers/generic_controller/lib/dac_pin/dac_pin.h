#ifndef DAC_PIN_H
#define DAC_PIN_H

#include <other_pin.h>

class DacPin: public OtherPin {
  public:
    DacPin() {};
    DacPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {
      pinMode(initialPhysicalPin, OUTPUT);
    };

    bool writeable();
    void writeIfAllowed(uint16_t value);
};

#endif