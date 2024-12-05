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
#include <ControllerStatus.h>

#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12
#define I2C_CLOCK_FREQUENCY 100000
#define ALIVE_FRAME_FREQUENCY_MS 100
#define ALLOWED_I2C_ERROR_TIMEFRAME 5000
#define VMS_ALLOWED_BOOT_TIME 30000
#define DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS 10
#define VMS_ALIVE_MS 100
#define VMS_VALID_FRAMES_WINDOW_SIZE 4
#define TOLERANCE_MS 10
#define MAX_I2C_RETRY 4

class Controller {
  public:
    Controller(
      AbstractBoard* mainBoard,
      AbstractBoard* expansionBoard1,
      AbstractBoard* expansionBoard2,
      AbstractCrc* crc,
      SerialTransfer* serialTransfer
    ){
      _status          = STARTING;
      _mainBoard       = mainBoard;
      _expansionBoard1 = expansionBoard1;
      _expansionBoard2 = expansionBoard2;
      _serialTransfer  = serialTransfer;
      _i2cRetryCount = 0;
      _vmsValidFramesWindow = 4;
      _configuration   = Configuration(mainBoard, expansionBoard1, expansionBoard2, crc, serialTransfer);
      _aliveEmittingTimestamp = 0;
      _digitalAndAnalogPinStatusesTimestamp = 0;
      _vmsAliveFrameCounter = 255;
      _lastI2cErrorTimestamp = 0;
    };
    void setup();
    void loop();

  private :
    ControllerStatus _status;
    uint8_t _vmsAliveTimeoutMs;
    unsigned long _latestVmsAliveTimestamp;
    uint8_t _vmsValidFramesWindow;
    uint8_t _i2cRetryCount;
    AbstractBoard* _mainBoard;
    AbstractBoard* _expansionBoard1;
    AbstractBoard* _expansionBoard2;
    SerialTransfer* _serialTransfer;
    AdoptionButton _adoptionButton;
    Can _can;
    Configuration _configuration;
    uint8_t _vmsAliveFrameCounter;
    unsigned long _aliveEmittingTimestamp;
    unsigned long _digitalAndAnalogPinStatusesTimestamp;
    unsigned long _lastI2cErrorTimestamp;

    void initializeSerial();
    void initializeSerialTransfer();
    void initializeI2C();
    void initializeExpansionBoards();
    void resetExpansionBoards();
    void writeDigitalPins();
    void shutdownAllDigitalPins();
    void writeOtherPins();
    void shutdownAllOtherPins();
    void setExternalPwm();
    void disablePwm();
    PinStatus *readDigitalPins();
    uint16_t* readAnalogPins();
    bool isReady();
    void adoptConfiguration();
    void shutdown(ControllerStatus controllerStatus);
    void emitPinStatuses();
    void emitAlive(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError);
    uint8_t verifyExpansionBoardErrors(uint8_t boardId);
    void watchVms();
    void watchExpansionBoards(uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError);
    void handleVmsCommandFrame();
};

#endif

