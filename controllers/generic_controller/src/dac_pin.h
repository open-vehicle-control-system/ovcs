#include <other_pin.h>

class DacPin: public OtherPin {
  public:
    DacPin() {};
    DacPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {
      pinMode(initialPhysicalPin, OUTPUT);
    };

    void write(uint16_t value);
};