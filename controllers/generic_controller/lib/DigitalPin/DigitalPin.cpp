#include <DigitalPin.h>

void DigitalPin::initPhysicalPin() {
  if (writeable()) {
    _board->pinMode(_physicalPin, OUTPUT);
    _board->digitalWrite(_physicalPin, 0);
  } else if (readable()) {
    _board->pinMode(_physicalPin, INPUT);
  }
};

bool DigitalPin::writeable() {
  return _status == DIGITAL_PIN_WRITE_ONLY || _status == DIGITAL_PIN_READ_WRITE;
};

bool DigitalPin::readable() {
  return _status == DIGITAL_PIN_READ_ONLY || _status == DIGITAL_PIN_READ_WRITE;
};

void DigitalPin::writeIfAllowed(bool value) {
  if (writeable()) {
    // Serial.print("PIN");
    // Serial.print(_physicalPin);
    // Serial.println(value);
    _board->digitalWrite(_physicalPin, value);
  }
};

uint8_t DigitalPin::readIfAllowed() {
  if (readable()) {
    return _board->digitalRead(_physicalPin);
  }
  return 0;
};
