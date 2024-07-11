#ifndef CONTROLLER_H
#define CONTROLLER_H

#include <Arduino.h>
#include <AdoptionButton.h>
#include <Can.h>
#include <Configuration.h>

#define I2C_CLOCK_FREQUENCY 100000
#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12

class Controller {
  public:
    Controller() {
      ready = false;
    };
    void setup();
    void loop();

  private :
    bool ready;
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

