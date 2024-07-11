#include <configuration.h>

bool Configuration::load() {
  uint32_t crc;
  uint32_t configurationCrc;
  uint8_t storedConfiguration [8];
  EEPROM.get(CONFIGURATION_EEPROM_ADDRESS, storedConfiguration);
  EEPROM.get(CONFIGURATION_CRC_EEPROM_ADDRESS, configurationCrc);
  crc = CRC32::calculate(storedConfiguration, CONFIGURATION_BYTE_SIZE);
  if (crc == configurationCrc) {
    rawConfiguration = storedConfiguration;
    computeControllerId();
    computeFrameIds();
    computeDigitalPins();
    computePwmPins();
    computeDacPin();
    computeAnalogPins();
    Serial.println("> EEPROM configuration valid, ready!");
    print();
    return true;
  } else {
    Serial.println("> EEPROM configuration invalid, adoption required!");
    return false;
  }
};

void Configuration::store(uint8_t newConfiguration[8]) {
  for(uint8_t i = 0; i < 8; i++) {
    EEPROM.update(CONFIGURATION_EEPROM_ADDRESS + i, newConfiguration[i]);
  }

  uint32_t crc = CRC32::calculate(newConfiguration , CONFIGURATION_BYTE_SIZE);
  EEPROM.put(CONFIGURATION_CRC_EEPROM_ADDRESS, crc);
};

void Configuration::storeAndApply(uint8_t newConfiguration[8]) {
  store(newConfiguration);
  load();
};

void Configuration::computeControllerId() {
  controllerId = rawConfiguration[0] >> 3;
};

void Configuration::computeFrameIds() {
  uint16_t shiftedId = controllerId << 3;
  aliveFrameId                      = shiftedId | ALIVE_FRAME_ID_MASK;
  digitalPinRequestFrameId          = shiftedId | DIGITAL_PIN_REQUEST_FRAME_ID_MASK;
  otherPinRequestFrameId            = shiftedId | OTHER_PIN_REQUEST_FRAME_ID_MASK;
  digitalAndAnalogPinsStatusFrameId = shiftedId | DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK;
};

void Configuration::computeDigitalPins() {
  uint8_t pinNumber = 0;
  for(uint8_t byteNumber = 1; byteNumber < 7; byteNumber++) {
    for (uint8_t i = 2; i < 9; i = i + 2) {
      if (pinNumber < 21) {
        uint8_t value          = (rawConfiguration[byteNumber] >> (8 - i)) & 0b11;
        uint8_t board          = digitalPinMapping[pinNumber][0];
        uint8_t physicalPin    = digitalPinMapping[pinNumber][1];
        digitalPins[pinNumber] = DigitalPin(value, board, physicalPin);
        pinNumber++;
      } else {
        i = 9;
      }
    }
  };
};

void Configuration::computePwmPins() {
  pwmPins[0] = PwmPin(rawConfiguration[6] >> 5 & 0b1, D5);
  pwmPins[1] = PwmPin(rawConfiguration[6] >> 4 & 0b1, D6);
  pwmPins[2] = PwmPin(rawConfiguration[6] >> 3 & 0b1, D9);
};

void Configuration::computeDacPin() {
  dacPin = DacPin(rawConfiguration[6] >> 2 & 0b1, A0);
};

void Configuration::computeAnalogPins() {
  analogPins[0] = AnalogPin(rawConfiguration[6] >> 1 & 0b1, A1);
  analogPins[1] = AnalogPin(rawConfiguration[6] & 0b1, A2);
  analogPins[2] = AnalogPin(rawConfiguration[7] >> 7 & 0b1, A3);
};

void Configuration::print() {
  Serial.println(">>>>> Current Configuration");

  Serial.print("> Raw configuration: ");
  for (uint8_t i = 0; i < 8; i++) {
    rawConfiguration[i] <= 0xF ? Serial.print("0") : Serial.print("");
    Serial.print(rawConfiguration[i], HEX);
    i == 7 ? Serial.println("") : Serial.print(" ");
  }

  Serial.print("> Controller ID: ");
  Serial.println(controllerId);

  Serial.print("> Alive frame ID: 0x");
  Serial.println(aliveFrameId, HEX);

  Serial.print("> Digital PIN request frame ID: 0x");
  Serial.println(digitalPinRequestFrameId, HEX);

  Serial.print("> Other PIN request frame ID: 0x");
  Serial.println(otherPinRequestFrameId, HEX);

  Serial.print("> Digital and analog PIN status frame ID: 0x");
  Serial.println(digitalAndAnalogPinsStatusFrameId, HEX);

  Serial.print("> Digital Pins: ");
  for(uint8_t i = 0; i < 21; i++) {
    DigitalPin digitalPin = digitalPins[i];
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
    pwmPins[i].writeable() ? Serial.print("ON") : Serial.print("OFF");
    Serial.print(" | ");
  }
  Serial.println("");

  Serial.print("> DAC Output Pin: ");
  dacPin.writeable() ? Serial.print("ON") : Serial.print("OFF");
  Serial.println("");

  Serial.print("> Analog Input Pins: ");
  for(uint8_t i = 0; i < 3; i++) {
    Serial.print(i);
    Serial.print(": ");
    analogPins[i].readable() ? Serial.print("ON") : Serial.print("OFF");
    Serial.print(" | ");
  }
  Serial.println("");
  Serial.println("<<<<<< Current Configuration");
};