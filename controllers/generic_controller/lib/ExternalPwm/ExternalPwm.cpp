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
    update(*this);
    delay(10);
  }
};

uint16_t ExternalPwm::dutyCycle() {
  return _dutyCycle;
};

uint32_t ExternalPwm::frequency() {
  return _frequency;
};

void ExternalPwm::update(ExternalPwm& externalPwm) {
  _enabled = externalPwm.enabled();
  _dutyCycle = externalPwm.dutyCycle();
  _frequency = externalPwm.frequency();

  uint16_t sendSize = 0;
  sendSize = _serialTransfer->txObj(_pwmId, sendSize);
  sendSize = _serialTransfer->txObj(_enabled, sendSize);
  sendSize = _serialTransfer->txObj(_dutyCycle, sendSize);
  sendSize = _serialTransfer->txObj(_frequency, sendSize, 3);
  _serialTransfer->sendData(sendSize, SET_PWM_COMMAND_ID);
};