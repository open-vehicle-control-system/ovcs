#include <DacPin.h>

bool DacPin::writeable() {
  return _enabled;
};

void DacPin::writeIfAllowed(uint16_t dutyCycle) {
  if (writeable()) {
    analogWrite(_physicalPin, dutyCycle);
  }
};