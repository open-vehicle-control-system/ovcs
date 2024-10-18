#ifndef EXTERNAL_PWM_H
#define EXTERNAL_PWM_H
#include <Arduino.h>
#include "SerialTransfer.h"
#define SET_PWM_COMMAND_ID 1

class ExternalPwm {
  public:
    ExternalPwm() {};
    ExternalPwm(uint8_t pwmId) {
      _pwmId     = pwmId;
      _enabled   = false;
      _dutyCycle = 0;
      _frequency = 0;
    };
    ExternalPwm(uint8_t pwmId, bool enabled, uint16_t dutyCycle, uint16_t frequency) {
      _pwmId     = pwmId;
      _enabled   = enabled;
      _dutyCycle = dutyCycle;
      _frequency = frequency;
    };
    uint8_t pwmId();
    void updateIfNeeded(ExternalPwm externalPwmRequest);
    bool enabled();
    uint16_t dutyCycle();
    uint16_t frequency();
  private:
    uint8_t _pwmId;
    bool _enabled;
    uint16_t _dutyCycle;
    uint16_t _frequency;
};

#endif