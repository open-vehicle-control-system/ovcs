#include <Configuration.h>

bool Configuration::load() {
  uint32_t crc;
  uint32_t configurationCrc;
  uint8_t storedConfiguration [8];
  EEPROM.get(CONFIGURATION_EEPROM_ADDRESS, storedConfiguration);
  EEPROM.get(CONFIGURATION_CRC_EEPROM_ADDRESS, configurationCrc);
  crc = _crc->crc32(storedConfiguration, CONFIGURATION_BYTE_SIZE);
  if (crc == configurationCrc) {
    _rawConfiguration = storedConfiguration;
    computeControllerId();
    computeFrameIds();
    computeDigitalPins();
    computePwmPins();
    computeDacPin();
    computeAnalogPins();
    computeExternalPwms();
    DPRINTLN("> EEPROM configuration valid, ready!");
    print();
    return true;
  } else {
    DPRINTLN("> EEPROM configuration invalid, adoption required!");
    return false;
  }
};

void Configuration::store(uint8_t newConfiguration[8]) {
  for(uint8_t i = 0; i < 8; i++) {
    EEPROM.update(CONFIGURATION_EEPROM_ADDRESS + i, newConfiguration[i]);
  }

  uint32_t crc = _crc->crc32(newConfiguration , CONFIGURATION_BYTE_SIZE);
  EEPROM.put(CONFIGURATION_CRC_EEPROM_ADDRESS, crc);
};

void Configuration::storeAndApply(uint8_t newConfiguration[8]) {
  store(newConfiguration);
  load();
};

void Configuration::computeControllerId() {
  _controllerId = _rawConfiguration[0] >> 4;
};

void Configuration::computeFrameIds() {
  uint16_t shiftedId = _controllerId << 4;
  _aliveFrameId                      = shiftedId | ALIVE_FRAME_ID_MASK;
  _digitalPinRequestFrameId          = shiftedId | DIGITAL_PIN_REQUEST_FRAME_ID_MASK;
  _otherPinRequestFrameId            = shiftedId | OTHER_PIN_REQUEST_FRAME_ID_MASK;
  _digitalAndAnalogPinsStatusFrameId = shiftedId | DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK;
  _externalPwm0RequestFrameId        = shiftedId | EXTERNAL_PWM0_REQUEST_FRAME_ID_MASK;
  _externalPwm1RequestFrameId        = shiftedId | EXTERNAL_PWM1_REQUEST_FRAME_ID_MASK;
  _externalPwm2RequestFrameId        = shiftedId | EXTERNAL_PWM2_REQUEST_FRAME_ID_MASK;
  _externalPwm3RequestFrameId        = shiftedId | EXTERNAL_PWM3_REQUEST_FRAME_ID_MASK;
};

void Configuration::computeDigitalPins() {
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 1; byteNumber < 6; byteNumber++) {
    for (uint8_t i = 2; i < 9; i = i + 2) {
      if (pinNumber < 19) {
        uint8_t status         = (_rawConfiguration[byteNumber] >> (8 - i)) & 0b11;
        uint8_t boardId        = digitalPinMapping[pinNumber][0];
        uint8_t physicalPin    = digitalPinMapping[pinNumber][1];
        AbstractBoard* board;
        switch (boardId) {
          case MAIN_BOARD_ID:
            board = _mainBoard;
            break;
          case EXPANSION_BOARD_ID_1:
            board = _expansionBoard1;
            break;
          case EXPANSION_BOARD_ID_2:
            board = _expansionBoard2;
            break;
        }
        _digitalPins[pinNumber] = DigitalPin(status, board, physicalPin);
        pinNumber++;
      } else {
        i = 9;
      }
    }
  };
};

void Configuration::computePwmPins() {
  _pwmPins[0] = PwmPin(_rawConfiguration[5] >> 1 & 0b1, D5);
  _pwmPins[1] = PwmPin(_rawConfiguration[5] & 0b1, D6);
  _pwmPins[2] = PwmPin(_rawConfiguration[6] >> 7 & 0b1, D9);
};

void Configuration::computeDacPin() {
  _dacPin = DacPin(_rawConfiguration[6] >> 6 & 0b1, A0);
};

void Configuration::computeAnalogPins() {
  _analogPins[0] = AnalogPin(_rawConfiguration[6] >> 5 & 0b1, A1);
  _analogPins[1] = AnalogPin(_rawConfiguration[6] >> 4 & 0b1, A2);
  _analogPins[2] = AnalogPin(_rawConfiguration[6] >> 3 & 0b1, A3);
};

void Configuration::computeExternalPwms() {
  _externalPwms[0] = ExternalPwm(0, _serialTransfert);
  _externalPwms[1] = ExternalPwm(1, _serialTransfert);
  _externalPwms[2] = ExternalPwm(2, _serialTransfert);
  _externalPwms[3] = ExternalPwm(3, _serialTransfert);
};

void Configuration::print() {
  #if DEBUG
    Serial.println(">>>>> Current Configuration");

    Serial.print("> Raw configuration: ");
    for (uint8_t i = 0; i < 8; i++) {
      _rawConfiguration[i] <= 0xF ? Serial.print("0") : Serial.print("");
      Serial.print(_rawConfiguration[i], HEX);
      i == 7 ? Serial.println("") : Serial.print(" ");
    }

    Serial.print("> Controller ID: ");
    Serial.println(_controllerId);

    Serial.print("> Alive frame ID: 0x");
    Serial.println(_aliveFrameId, HEX);

    Serial.print("> Digital PIN request frame ID: 0x");
    Serial.println(_digitalPinRequestFrameId, HEX);

    Serial.print("> Other PIN request frame ID: 0x");
    Serial.println(_otherPinRequestFrameId, HEX);

    Serial.print("> Digital and analog PIN status frame ID: 0x");
    Serial.println(_digitalAndAnalogPinsStatusFrameId, HEX);

    Serial.print("> External PWM0 request frame ID: 0x");
    Serial.println(_externalPwm0RequestFrameId, HEX);

    Serial.print("> External PWM1 request frame ID: 0x");
    Serial.println(_externalPwm1RequestFrameId, HEX);

    Serial.print("> External PWM2 request frame ID: 0x");
    Serial.println(_externalPwm2RequestFrameId, HEX);

    Serial.print("> External PWM3 request frame ID: 0x");
    Serial.println(_externalPwm3RequestFrameId, HEX);

    Serial.print("> Digital Pins: ");
    for(uint8_t i = 0; i < 19; i++) {
      DigitalPin digitalPin = _digitalPins[i];
      Serial.print(i);
      Serial.print(": ");
      if (digitalPin.writeable() && digitalPin.readable()) {
        Serial.print("RW");
      } else if (digitalPin.writeable()) {
        Serial.print("W");
      } else if (digitalPin.readable()) {
        Serial.print("R");
      } else {
        Serial.print("_");
      }
      Serial.print(" | ");
    }
    Serial.println("");

    Serial.print("> PWM Output Pins: ");
    for(uint8_t i = 0; i < 3; i++) {
      Serial.print(i);
      Serial.print(": ");
      _pwmPins[i].writeable() ? Serial.print("ON") : Serial.print("OFF");
      Serial.print(" | ");
    }
    Serial.println("");

    Serial.print("> DAC Output Pin: ");
    _dacPin.writeable() ? Serial.print("ON") : Serial.print("OFF");
    Serial.println("");

    Serial.print("> Analog Input Pins: ");
    for(uint8_t i = 0; i < 3; i++) {
      Serial.print(i);
      Serial.print(": ");
      _analogPins[i].readable() ? Serial.print("ON") : Serial.print("OFF");
      Serial.print(" | ");
    }
    Serial.println("");
    Serial.println("<<<<<< Current Configuration");
  #endif
};