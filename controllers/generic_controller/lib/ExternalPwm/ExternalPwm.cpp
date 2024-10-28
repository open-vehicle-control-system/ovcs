#include "ExternalPwm.h"

uint8_t ExternalPwm::pwmId() {
  return _pwmId;
};

bool ExternalPwm::enabled() {
  return _enabled;
};

uint16_t ExternalPwm::dutyCycle() {
  return _dutyCycle;
};

uint16_t ExternalPwm::frequency() {
  return _frequency;
};

void ExternalPwm::updateIfNeeded(ExternalPwm& externalPwm) {
  // if (
  //     externalPwm.enabled() != _enabled ||
  //     externalPwm.dutyCycle() != _dutyCycle ||
  //     externalPwm.frequency() != _frequency) {
    _enabled = externalPwm.enabled();
    _dutyCycle = externalPwm.dutyCycle();
    _frequency = externalPwm.frequency();
    uint16_t sendSize = 0;
    sendSize = _serialTransfer->txObj(_pwmId, sendSize);
    sendSize = _serialTransfer->txObj(_enabled, sendSize);
    sendSize = _serialTransfer->txObj(_dutyCycle, sendSize);
    sendSize = _serialTransfer->txObj(_frequency, sendSize);
    _serialTransfer->sendData(sendSize, SET_PWM_COMMAND_ID);
 // }
};