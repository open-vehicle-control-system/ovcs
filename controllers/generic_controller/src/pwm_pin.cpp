#include <pwm_pin.h>

void PwmPin::write(uint16_t dutyCycle) {
  analogWrite(physicalPin, dutyCycle);
};