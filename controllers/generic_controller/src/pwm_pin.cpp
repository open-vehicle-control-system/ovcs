#include <pwm_pin.h>

void PwmPin::writeIfAllowed(uint16_t dutyCycle) {
  if(writeable()){
    analogWrite(physicalPin, dutyCycle);
  }
};