#include <DigitalPin.h>

void DigitalPin::initPhysicalPin() {
  if (writeable() || readable()){
    switch (board) {
      case MAIN_BOARD_ID:
        pinMode(physicalPin, physicalPinMode());
        break;
      case MOSFET_0_ID:
        MOSFETBoard1.pinMode1(physicalPin, physicalPinMode());
        if (writeable()) {
          MOSFETBoard1.write1(physicalPin, 0);
        }
        break;
      case MOSFET_1_ID:
        MOSFETBoard2.pinMode1(physicalPin, physicalPinMode());
        if (writeable()) {
          MOSFETBoard2.write1(physicalPin, 0);
        }
        break;
    }
  }
};

uint8_t DigitalPin::physicalPinMode() {
  if (writeable()) {
    return OUTPUT;
  } else {
    return INPUT;
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
    switch (board) {
      case MAIN_BOARD_ID:
        digitalWrite(physicalPin, value);
        break;
      case MOSFET_0_ID:
        MOSFETBoard1.write1(physicalPin, value);
        break;
      case MOSFET_1_ID:
        MOSFETBoard2.write1(physicalPin, value);
        break;
    }
  }
};

uint8_t DigitalPin::readIfAllowed() {
  if (readable()) {
    switch (board) {
      case MAIN_BOARD_ID:
        return digitalRead(physicalPin);
        break;
      case MOSFET_0_ID:
        return MOSFETBoard1.read1(physicalPin);
        break;
      case MOSFET_1_ID:
        return MOSFETBoard2.read1(physicalPin);
        break;
    }
  } else {
    return 0;
  }
};