#ifndef CONFIGURATION_H
#define CONFIGURATION_H
#include <Arduino.h>
#include <digital_pin.h>
#include <other_pin.h>
#include <CRC32.h>
#include <EEPROM.h>
#include <ACAN2517.h>

#define ALIVE_FRAME_ID_MASK 0x700
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x701
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x702
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x703
#define CONFIGURATION_EEPROM_ADDRESS 0
#define CONFIGURATION_CRC_EEPROM_ADDRESS 64
#define CONFIGURATION_BYTE_SIZE 8

class Configuration {
  public :
    uint8_t* rawConfiguration;
    uint8_t  controllerId;
    DigitalPin digitalPins [21];
    OtherPin pwmPins [3];
    OtherPin dacPin;
    OtherPin analogPins [3];
    uint16_t aliveFrameId;
    uint16_t digitalPinRequestFrameId;
    uint16_t otherPinRequestFrameId;
    uint16_t digitalAndAnalogPinStatusFrameId;

    Configuration() {};
    Configuration(uint8_t initialRawConfiguration [8]) {
      rawConfiguration = initialRawConfiguration;
    };

    void computeControllerId();
    void computeFrameIds();
    void computeDigitalPins();
    void computePwmPins();
    void computeDacPin();
    void computeAnalogPins();
    void print();
    void store(CANMessage framen);
    void storeAndApply(CANMessage frame);
    bool load();
};

#endif