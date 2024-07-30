#include <AnalogPin.h>

bool AnalogPin::readable() {
  return _enabled;
};

uint16_t AnalogPin::readIfAllowed() {
  if (readable()) {
    return analogRead(_physicalPin);
  } else {
    return 0;
  }
};