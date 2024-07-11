#include <DacPin.h>

bool DacPin::writeable() {
  return enabled;
};

void DacPin::writeIfAllowed(uint16_t dutyCycle) {
  if (writeable()) {
    analogWrite(physicalPin, dutyCycle);
  }
};