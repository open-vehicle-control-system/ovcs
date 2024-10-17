#ifndef EXTERNAL_PWM_REQUEST_H
#define EXTERNAL_PWM_REQUEST_H
#include <Arduino.h>



struct OtherPinDutyCycles{
    uint16_t dacDutyCycle = 0;
    uint16_t pwmDutyCyles [3] = {0, 0, 0};
};
#endif