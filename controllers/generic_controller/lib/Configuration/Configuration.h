#ifndef CONFIGURATION_H
#define CONFIGURATION_H
#include <Arduino.h>
#include <DigitalPin.h>
#include <PwmPin.h>
#include <DacPin.h>
#include <AnalogPin.h>
#include <CRC32.h>
#include <EEPROM.h>

#define ALIVE_FRAME_ID_MASK 0x701
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x702
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x703
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x704
#define CONFIGURATION_EEPROM_ADDRESS 0
#define CONFIGURATION_CRC_EEPROM_ADDRESS 8
#define CONFIGURATION_BYTE_SIZE 8

class Configuration {
  public :
    DigitalPin digitalPins [21];
    PwmPin pwmPins [3];
    DacPin dacPin;
    AnalogPin analogPins [3];
    uint16_t aliveFrameId;
    uint16_t digitalPinRequestFrameId;
    uint16_t otherPinRequestFrameId;
    uint16_t digitalAndAnalogPinsStatusFrameId;
    bool load();
    void storeAndApply(uint8_t newConfiguration[8]);

    Configuration() {};
    Configuration(uint8_t initialRawConfiguration [8]) {
      rawConfiguration = initialRawConfiguration;
    };

  private:
    uint8_t  controllerId;
    uint8_t* rawConfiguration;
    void store(uint8_t newConfiguration[8]);
    void computeControllerId();
    void computeFrameIds();
    void computeDigitalPins();
    void computePwmPins();
    void computeDacPin();
    void computeAnalogPins();
    void print();
};

#endif