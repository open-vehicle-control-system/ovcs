#ifndef CONTROLLER_H
#define CONTROLLER_H

#include <Arduino.h>
#include <ACAN2517.h>
#include <digital_pin.h>
#include <adoption_button.h>
#include <can.h>
#include <configuration.h>

#define I2C_CLOCK_FREQUENCY 100000
#define ADOPTION_FRAME_ID 0x700
#define ANALOG_READ_RESOLUTION 14
#define ANALOG_WRITE_RESOLUTION 12

class Controller {
  public :
    bool ready;
    AdoptionButton adoptionButton;
    Can can;
    Configuration configuration;
    Controller() {
      ready = false;
    };
    void initializeSerial();
    void initializeI2C();
    void setup();
    void adoptConfiguration();
    void setDigitalPins();
    void setPwmPins();
    void setDacPin();
    uint8_t* readDigitalPins();
    uint16_t* readAnalogPins();
    void sendPinStatuses();
    bool isReady();
    void loop();
    void emitPinStatuses();
};

#endif

