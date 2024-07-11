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
    Controller(AbstractBoard* initialMainBoard, AbstractBoard* initialMosfetBoard1, AbstractBoard* initialMosfetBoard2){
      ready         = false;
      mainBoard     = initialMainBoard;
      mosfetBoard1  = initialMosfetBoard1;
      mosfetBoard2  = initialMosfetBoard2;
      configuration = Configuration(mosfetBoard1, mosfetBoard2, initialMosfetBoard2);
    };
    void setup();
    void loop();

  private :
    bool ready;
    AbstractBoard* mosfetBoard1;
    AbstractBoard* mosfetBoard2;
    AbstractBoard* mainBoard;
    AdoptionButton adoptionButton;
    Can can;
    Configuration configuration;
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

