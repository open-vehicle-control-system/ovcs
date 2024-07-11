#include <DigitalPin.h>

void DigitalPin::initPhysicalPin() {
  if (writeable()) {
    board->pinMode(physicalPin, OUTPUT);
    board->digitalWrite(physicalPin, 0);
  } else if (readable()) {
    board->pinMode(physicalPin, INPUT);
  }
};

bool DigitalPin::writeable() {
  return status == DIGITAL_PIN_WRITE_ONLY || status == DIGITAL_PIN_READ_WRITE;
};

bool DigitalPin::readable() {
  return status == DIGITAL_PIN_READ_ONLY || status == DIGITAL_PIN_READ_WRITE;
};

void DigitalPin::writeIfAllowed(bool value) {
  if (writeable()) {
    if (value == 1) {
      Serial.println("Writable");
      Serial.println(physicalPin);
      Serial.println(value);
    }
    board->digitalWrite(physicalPin, value);
  }
};

uint8_t DigitalPin::readIfAllowed() {
  if (readable()) {
    board->digitalRead(physicalPin);
  }
  return 0;
};
