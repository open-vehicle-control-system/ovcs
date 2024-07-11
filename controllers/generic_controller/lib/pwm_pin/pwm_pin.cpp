#include <pwm_pin.h>

bool PwmPin::writeable() {
  return enabled;
};

void PwmPin::writeIfAllowed(uint16_t dutyCycle) {
  if (writeable()) {
    analogWrite(physicalPin, dutyCycle);
  }
};