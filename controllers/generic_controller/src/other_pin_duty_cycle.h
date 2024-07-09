#ifndef OTHER_PIN_DUTY_CYCLE_H
#define OTHER_PIN_DUTY_CYCLE_H

#include <Arduino.h>

struct OtherPinDutyCycles{
    uint16_t dacDutyCycle;
    uint16_t pwmDutyCyles [3] = {0, 0, 0};
};

#endif
