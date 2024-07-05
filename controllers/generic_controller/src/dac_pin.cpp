#include <dac_pin.h>

void DacPin::write(uint16_t dutyCycle) {
  analogWrite(physicalPin, dutyCycle);
};