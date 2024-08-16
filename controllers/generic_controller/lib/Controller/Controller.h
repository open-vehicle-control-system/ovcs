#ifndef CONTROLLER_H
#define CONTROLLER_H

#include <Arduino.h>
#include <AdoptionButton.h>
#include <Can.h>
#include <Configuration.h>
#include <AbstractBoard.h>

#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12

class Controller {
  public:
    Controller(AbstractBoard* mainBoard, AbstractBoard* mosfetBoard1, AbstractBoard* mosfetBoard2, AbstractCrc* crc){
      _ready         = false;
      _mainBoard     = mainBoard;
      _mosfetBoard1  = mosfetBoard1;
      _mosfetBoard2  = mosfetBoard2;
      _configuration = Configuration(mainBoard, mosfetBoard1, mosfetBoard2, crc);
    };
    void setup();
    void loop();

  private :
    bool _ready;
    AbstractBoard* _mainBoard;
    AbstractBoard* _mosfetBoard1;
    AbstractBoard* _mosfetBoard2;
    AdoptionButton _adoptionButton;
    Can _can;
    Configuration _configuration;
    void initializeSerial();
    void initializeI2C();
    void writeDigitalPins();
    void writeOtherPins();
    uint8_t* readDigitalPins();
    uint16_t* readAnalogPins();
    bool isReady();
    void adoptConfiguration();
    void emitPinStatuses();
    void emitFrames();

};

#endif

