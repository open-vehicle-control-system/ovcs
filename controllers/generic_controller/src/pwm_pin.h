#include <other_pin.h>

class PwmPin: public OtherPin {
  public:
    PwmPin() {};
    PwmPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {
      pinMode(initialPhysicalPin, OUTPUT);
    };
    void writeIfAllowed(uint16_t dutyCycle);
};