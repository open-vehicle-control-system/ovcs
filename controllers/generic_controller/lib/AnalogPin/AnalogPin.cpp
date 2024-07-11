#include <AnalogPin.h>

bool AnalogPin::readable() {
  return enabled;
};

uint8_t AnalogPin::readIfAllowed() {
  if (readable()) {
    return analogRead(physicalPin);
  } else {
    return 0;
  }
};