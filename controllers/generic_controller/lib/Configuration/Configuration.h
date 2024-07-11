#ifndef CONFIGURATION_H
#define CONFIGURATION_H
#include <Arduino.h>
#include <DigitalPin.h>
#include <PwmPin.h>
#include <DacPin.h>
#include <AnalogPin.h>
#include <CRC32.h>
#include <EEPROM.h>
#include <AbstractBoard.h>

#define ALIVE_FRAME_ID_MASK 0x701
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x702
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x703
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x704
#define CONFIGURATION_EEPROM_ADDRESS 0
#define CONFIGURATION_CRC_EEPROM_ADDRESS 8
#define CONFIGURATION_BYTE_SIZE 8

#define MAIN_BOARD_ID 0
#define MOSFET_0_ID 1
#define MOSFET_1_ID 2

const uint8_t digitalPinMapping [21][2] = {
  {MAIN_BOARD_ID, D0},
  {MAIN_BOARD_ID, D1},
  {MAIN_BOARD_ID, D4},
  {MAIN_BOARD_ID, D7},
  {MAIN_BOARD_ID, D8},
  {MOSFET_0_ID, 0},
  {MOSFET_0_ID, 1},
  {MOSFET_0_ID, 2},
  {MOSFET_0_ID, 3},
  {MOSFET_0_ID, 4},
  {MOSFET_0_ID, 5},
  {MOSFET_0_ID, 6},
  {MOSFET_0_ID, 7},
  {MOSFET_1_ID, 0},
  {MOSFET_1_ID, 1},
  {MOSFET_1_ID, 2},
  {MOSFET_1_ID, 3},
  {MOSFET_1_ID, 4},
  {MOSFET_1_ID, 5},
  {MOSFET_1_ID, 6},
  {MOSFET_1_ID, 7},
};

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
    Configuration(AbstractBoard* initialMosfetBoard1, AbstractBoard* initialMosfetBoard2, AbstractBoard* iniitalMainBoard) {
      mosfetBoard1 = initialMosfetBoard1;
      mosfetBoard2 = initialMosfetBoard2;
      mainBoard = iniitalMainBoard;
    };

  private:
    uint8_t  controllerId;
    uint8_t* rawConfiguration;
    AbstractBoard* mosfetBoard1;
    AbstractBoard* mosfetBoard2;
    AbstractBoard* mainBoard;
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