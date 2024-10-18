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

void ExternalPwm::updateIfNeeded(ExternalPwm externalPwmRequest) {
  if (
      externalPwmRequest.enabled() != _enabled ||
      externalPwmRequest.dutyCycle() != _dutyCycle ||
      externalPwmRequest.frequency() != _frequency) {
    _enabled = externalPwmRequest.enabled();
    _dutyCycle = externalPwmRequest.dutyCycle();
    _frequency = externalPwmRequest.frequency();
    SerialTransfer serialTransfer;
    uint16_t sendSize = 0;
    sendSize = serialTransfer.txObj(_pwmId, sendSize);
    sendSize = serialTransfer.txObj(_enabled, sendSize);
    sendSize = serialTransfer.txObj(_dutyCycle, sendSize);
    sendSize = serialTransfer.txObj(_frequency, sendSize);

    serialTransfer.sendData(sendSize, SET_PWM_COMMAND_ID);
  }
};