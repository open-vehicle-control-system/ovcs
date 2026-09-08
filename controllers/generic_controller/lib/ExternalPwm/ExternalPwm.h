#ifndef EXTERNAL_PWM_H
#define EXTERNAL_PWM_H
#include <Arduino.h>
// The serial link to the PWM hat is hardware; the native test build
// only needs the type to exist, as AbstractBoard does with TestTypes.
#ifdef LOCAL_TEST
  class SerialTransfer;
#else
  #include "SerialTransfer.h"
#endif
#define SET_PWM_COMMAND_ID 1
// How long an unchanged setting may go without being resent to the
// hat. The link has no acknowledgement: a packet the hat drops would
// otherwise stay lost, and the output stuck, until the setting next
// changes. 100 ms bounds that to a tenth of a second while keeping
// the four channels to 40 packets/s instead of one per request frame.
#define EXTERNAL_PWM_REFRESH_INTERVAL_MS 100

class ExternalPwm {
  public:
    ExternalPwm() {};
    ExternalPwm(uint8_t pwmId, SerialTransfer* serialTransfer) {
      _pwmId     = pwmId;
      _enabled   = false;
      _dutyCycle = 0;
      _frequency = 0;
      _serialTransfer = serialTransfer;
    };
    ExternalPwm(uint8_t pwmId, bool enabled, uint16_t dutyCycle, uint32_t frequency) {
      _pwmId     = pwmId;
      _enabled   = enabled;
      _dutyCycle = dutyCycle;
      _frequency = frequency;
    };
    uint8_t pwmId();
    bool differsFrom(ExternalPwm& other);
    bool needsRelay(ExternalPwm& request, unsigned long now);
    void update(ExternalPwm& externalPwm, unsigned long now);
    bool enabled();
    void disable();
    uint16_t dutyCycle();
    uint32_t frequency();
  private:
    uint8_t _pwmId;
    bool _enabled;
    uint16_t _dutyCycle;
    uint32_t _frequency;
    unsigned long _lastSentAt = 0;
    SerialTransfer* _serialTransfer;
};

#endif