#ifndef CONTROLLER_H
#define CONTROLLER_H

#include <Arduino.h>
#include <AdoptionButton.h>
#include <Can.h>
#include <Configuration.h>
#include <AbstractBoard.h>
#include <Wire.h>
#include <SerialTransfer.h>
#include <ExternalPwm.h>

#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12
#define I2C_CLOCK_FREQUENCY 100000
#define ALIVE_FRAME_FREQUENCY_MS 100
#define DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS 10

class Controller {
  public:
    Controller(
      AbstractBoard* mainBoard,
      AbstractBoard* expansionBoard1,
      AbstractBoard* expansionBoard2,
      AbstractCrc* crc,
      SerialTransfer* serialTransfer
    ){
      _ready           = false;
      _mainBoard       = mainBoard;
      _expansionBoard1 = expansionBoard1;
      _expansionBoard2 = expansionBoard2;
      _serialTransfer  = serialTransfer;
      _configuration   = Configuration(mainBoard, expansionBoard1, expansionBoard2, crc, serialTransfer);
      _aliveEmittingTimestamp = 0;
      _digitalAndAnalogPinStatusesTimestamp = 0;
    };
    void setup();
    void loop();

  private :
    bool _ready;
    AbstractBoard* _mainBoard;
    AbstractBoard* _expansionBoard1;
    AbstractBoard* _expansionBoard2;
    SerialTransfer* _serialTransfer;
    AdoptionButton _adoptionButton;
    Can _can;
    Configuration _configuration;
    unsigned long _aliveEmittingTimestamp;
    unsigned long _digitalAndAnalogPinStatusesTimestamp;
    void initializeSerial();
    void initializeSerialTransfer();
    void initializeI2C();
    void writeDigitalPins();
    void writeOtherPins();
    void setExternalPwm();
    PinStatus *readDigitalPins();
    uint16_t* readAnalogPins();
    bool isReady();
    void adoptConfiguration();
    void emitPinStatuses();
    void emitFrames(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError);
    uint8_t verifyExpansionBoardErrors(uint8_t boardId);
};

#endif

