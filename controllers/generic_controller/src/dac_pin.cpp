#include <dac_pin.h>

void DacPin::writeIfAllowed(uint16_t dutyCycle) {
  if(writeable()){
    analogWrite(physicalPin, dutyCycle);
  }
};