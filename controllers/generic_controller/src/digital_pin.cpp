#include <digital_pin.h>

void DigitalPin::initPhysicalPin() {
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

void DigitalPin::write(bool value) {
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
};