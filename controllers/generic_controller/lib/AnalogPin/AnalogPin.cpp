#include <AnalogPin.h>

bool AnalogPin::readable() {
  return enabled;
};

uint8_t AnalogPin::read() {
  return analogRead(physicalPin);
};