#include <DigitalPin.h>

void DigitalPin::initializePhysicalPin() {
  if (writeable()) {
    _board->pinMode(_physicalPin, OUTPUT);
    _board->digitalWrite(_physicalPin, LOW);

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

void DigitalPin::writeIfAllowed(PinStatus status) {
  if (writeable()) {
    // _board->pinMode(_physicalPin, (PinMode)1);
    _board->digitalWrite(_physicalPin, status);
  }
};

PinStatus DigitalPin::readIfAllowed() {
  if (readable()) {
    return _board->digitalRead(_physicalPin);
  }
  return LOW;
};
