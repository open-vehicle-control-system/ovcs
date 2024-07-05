#include <other_pin.h>

class AnalogPin: public OtherPin {
  public:
    AnalogPin() {};
    AnalogPin(bool initialEnabled, uint8_t initialPhysicalPin) : OtherPin(initialEnabled, initialPhysicalPin) {};
};