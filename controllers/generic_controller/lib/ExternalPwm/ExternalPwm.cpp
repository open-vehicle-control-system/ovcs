#include "ExternalPwm.h"

uint8_t ExternalPwm::pwmId() {
  return _pwmId;
};

bool ExternalPwm::enabled() {
  return _enabled;
};

void ExternalPwm::disable() {
  _dutyCycle = 0;
  _frequency = 0;
  _enabled = false;
  for(uint8_t i = 0; i < 10; i++) {
    update(*this, millis());
    delay(10);
  }
};

uint16_t ExternalPwm::dutyCycle() {
  return _dutyCycle;
};

uint32_t ExternalPwm::frequency() {
  return _frequency;
};

// True when applying `other` would change what the hat outputs. Only
// the payload fields count; the id is what routed the request here.
bool ExternalPwm::differsFrom(ExternalPwm& other) {
  return _enabled != other.enabled()
      || _dutyCycle != other.dutyCycle()
      || _frequency != other.frequency();
};

// A request is relayed when it changes the output, or when the current
// setting has not been confirmed to the hat for
// EXTERNAL_PWM_REFRESH_INTERVAL_MS. Unsigned subtraction keeps the
// comparison correct across millis() wrap-around.
bool ExternalPwm::needsRelay(ExternalPwm& request, unsigned long now) {
  return differsFrom(request)
      || (now - _lastSentAt) >= EXTERNAL_PWM_REFRESH_INTERVAL_MS;
};

void ExternalPwm::update(ExternalPwm& externalPwm, unsigned long now) {
  _enabled = externalPwm.enabled();
  _dutyCycle = externalPwm.dutyCycle();
  _frequency = externalPwm.frequency();
  _lastSentAt = now;

#ifndef LOCAL_TEST
  uint16_t sendSize = 0;
  sendSize = _serialTransfer->txObj(_pwmId, sendSize);
  sendSize = _serialTransfer->txObj(_enabled, sendSize);
  sendSize = _serialTransfer->txObj(_dutyCycle, sendSize);
  sendSize = _serialTransfer->txObj(_frequency, sendSize, 3);
  _serialTransfer->sendData(sendSize, SET_PWM_COMMAND_ID);
#endif
};