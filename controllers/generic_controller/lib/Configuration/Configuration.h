#ifndef CONFIGURATION_H
#define CONFIGURATION_H
#include <Arduino.h>
#include <Debug.h>
#include <DigitalPin.h>
#include <PwmPin.h>
#include <DacPin.h>
#include <AnalogPin.h>
#include <EEPROM.h>
#include <AbstractBoard.h>
#include <AbstractCrc.h>
#include <ExternalPwm.h>

#define ALIVE_FRAME_ID_MASK 0x701
#define DIGITAL_PIN_REQUEST_FRAME_ID_MASK 0x702
#define OTHER_PIN_REQUEST_FRAME_ID_MASK 0x703
#define DIGITAL_AND_ANALOG_PIN_STATUS_FRAME_ID_MASK 0x704
#define EXTERNAL_PWM0_REQUEST_FRAME_ID_MASK 0x705
#define EXTERNAL_PWM1_REQUEST_FRAME_ID_MASK 0x706
#define EXTERNAL_PWM2_REQUEST_FRAME_ID_MASK 0x707
#define EXTERNAL_PWM3_REQUEST_FRAME_ID_MASK 0x708
#define VMS_ALIVE_FRAME_ID_MASK 0x1A0
#define CONFIGURATION_EEPROM_ADDRESS 0
#define CONFIGURATION_CRC_EEPROM_ADDRESS 8
#define CONFIGURATION_BYTE_SIZE 8

#define MAIN_BOARD_ID 0
#define EXPANSION_BOARD_ID_1 1
#define EXPANSION_BOARD_ID_2 2

const uint8_t digitalPinMapping [19][2] = {
  {MAIN_BOARD_ID, D4},
  {MAIN_BOARD_ID, D7},
  {MAIN_BOARD_ID, D8},
  {EXPANSION_BOARD_ID_1, 0},
  {EXPANSION_BOARD_ID_1, 1},
  {EXPANSION_BOARD_ID_1, 2},
  {EXPANSION_BOARD_ID_1, 3},
  {EXPANSION_BOARD_ID_1, 4},
  {EXPANSION_BOARD_ID_1, 5},
  {EXPANSION_BOARD_ID_1, 6},
  {EXPANSION_BOARD_ID_1, 7},
  {EXPANSION_BOARD_ID_2, 0},
  {EXPANSION_BOARD_ID_2, 1},
  {EXPANSION_BOARD_ID_2, 2},
  {EXPANSION_BOARD_ID_2, 3},
  {EXPANSION_BOARD_ID_2, 4},
  {EXPANSION_BOARD_ID_2, 5},
  {EXPANSION_BOARD_ID_2, 6},
  {EXPANSION_BOARD_ID_2, 7},
};

class Configuration {
  public :
    DigitalPin _digitalPins [19];
    PwmPin _pwmPins [3];
    DacPin _dacPin;
    AnalogPin _analogPins [3];
    ExternalPwm _externalPwms [4];
    uint16_t _aliveFrameId;
    uint16_t _digitalPinRequestFrameId;
    uint16_t _otherPinRequestFrameId;
    uint16_t _digitalAndAnalogPinsStatusFrameId;
    uint16_t _externalPwm0RequestFrameId;
    uint16_t _externalPwm1RequestFrameId;
    uint16_t _externalPwm2RequestFrameId;
    uint16_t _externalPwm3RequestFrameId;
    bool _expansionBoard1InUse;
    bool _expansionBoard2InUse;
    uint16_t _vmsAliveFrameId;

    bool load();
    void storeAndApply(uint8_t newConfiguration[8]);

    Configuration() {};
    Configuration(
      AbstractBoard* mainBoard,
      AbstractBoard* expansionBoard1,
      AbstractBoard* expansionBoard2,
      AbstractCrc* crc,
      SerialTransfer* serialTransfert
    ) {
      _mainBoard       = mainBoard;
      _expansionBoard1 = expansionBoard1;
      _expansionBoard2 = expansionBoard2;
      _crc             = crc;
      _serialTransfert = serialTransfert;
      _expansionBoard1InUse = false;
      _expansionBoard2InUse = false;
    };

  private:
    uint8_t  _controllerId;
    uint8_t* _rawConfiguration;
    AbstractBoard* _mainBoard;
    AbstractBoard* _expansionBoard1;
    AbstractBoard* _expansionBoard2;
    AbstractCrc* _crc;
    SerialTransfer* _serialTransfert;
    void store(uint8_t newConfiguration[8]);
    void computeControllerId();
    void computeFrameIds();
    void computeDigitalPins();
    void computePwmPins();
    void computeDacPin();
    void computeAnalogPins();
    void computeExternalPwms();
    void print();
};

#endif