#ifndef EXTERNAL_PWM_H
#define EXTERNAL_PWM_H
#include <Arduino.h>

class ExternalPwm {
  public:
    ExternalPwm(uint8_t pwmId) {
      _pwmId = pwmId;
      _enabled = false;
      _dutyCycle = 0;
      _frequency = 0;
    };
  private:
    uint8_t _pwmId;
    bool _enabled;
    uint16_t _dutyCycle;
    uint16_t _frequency;
};

#endif