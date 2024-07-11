#include <PwmPin.h>

bool PwmPin::writeable() {
  return _enabled;
};

void PwmPin::writeIfAllowed(uint16_t dutyCycle) {
  if (writeable()) {
    analogWrite(_physicalPin, dutyCycle);
  }
};