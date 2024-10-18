#ifndef CONTROLLER_H
#define CONTROLLER_H

#include <Arduino.h>
#include <AdoptionButton.h>
#include <Can.h>
#include <Configuration.h>
#include <AbstractBoard.h>
#include <Wire.h>
#include "SerialTransfer.h"
#include <ExternalPwm.h>

#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12
#define I2C_CLOCK_FREQUENCY 100000

class Controller {
  public:
    Controller(AbstractBoard* mainBoard, AbstractBoard* expansionBoard1, AbstractBoard* expansionBoard2, AbstractCrc* crc){
      _ready           = false;
      _mainBoard       = mainBoard;
      _expansionBoard1 = expansionBoard1;
      _expansionBoard2 = expansionBoard2;
      _configuration   = Configuration(mainBoard, expansionBoard1, expansionBoard2, crc);
    };
    void setup();
    void loop();

  private :
    bool _ready;
    AbstractBoard* _mainBoard;
    AbstractBoard* _expansionBoard1;
    AbstractBoard* _expansionBoard2;
    AdoptionButton _adoptionButton;
    Can _can;
    Configuration _configuration;
    void initializeSerial();
    void initializeI2C();
    void writeDigitalPins();
    void writeOtherPins();
    void setExternalPwm();
    PinStatus *readDigitalPins();
    uint16_t* readAnalogPins();
    bool isReady();
    void adoptConfiguration();
    void emitPinStatuses();
    void emitFrames();

};

#endif

