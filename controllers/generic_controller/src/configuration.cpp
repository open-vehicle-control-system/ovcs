#include <configuration.h>

void Configuration::computeControllerId() {
  controllerId = rawConfiguration[0] >> 3;
};

void Configuration::computeFrameIds() {
  uint16_t shiftedId = controllerId << 3;
  aliveFrameId                     = shiftedId | ALIVE_FRAME_ID_MASK;
  digitalPinRequestFrameId         = shiftedId | DIGITAL_PIN_REQUEST_FRAME_ID_MASK;
  otherPinRequestFrameId           = shiftedId | OTHER_PIN_REQUEST_FRAME_ID_MASK;
  digitalAndAnalogPinStatusFrameId = shiftedId | DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK;
};

void Configuration::computeDigitalPins() {
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 1; byteNumber < 7; byteNumber++) {
    for (uint8_t i = 2; i < 9; i = i + 2) {
      if (pinNumber < 21) {
        uint8_t value          = (rawConfiguration[byteNumber] >> (8 - i)) & 3;
        uint8_t board          = digitalPinMapping[pinNumber][0];
        uint8_t physicalPin    = digitalPinMapping[pinNumber][1];
        digitalPins[pinNumber] = DigitalPin(value, board, physicalPin);
        pinNumber++;
      }
    }
  };
};
void Configuration::computePwmPins() {
  pwmPins[0] = OtherPin(rawConfiguration[6] >> 5 & 1, D5);
  pwmPins[1] = OtherPin(rawConfiguration[6] >> 4 & 1, D6);
  pwmPins[2] = OtherPin(rawConfiguration[6] >> 3 & 1, D9);
};
void Configuration::computeDacPin() {
  dacPin = OtherPin(rawConfiguration[6] >> 2 & 1, A0);
};
void Configuration::computeAnalogPins() {
  analogPins[0] = OtherPin(rawConfiguration[6] >> 1 & 1, A1);
  analogPins[1] = OtherPin(rawConfiguration[6]  & 1, A2);
  analogPins[2] = OtherPin(rawConfiguration[7] >> 7 & 1, A3);
};
