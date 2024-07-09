#ifndef CAN_H
#define CAN_H

#include <Arduino.h>
#include <ACAN2517.h>
#include <SPI.h>
#include <other_pin_duty_cycle.h>

#define ALIVE_FRAME_FREQUENCY_MS 100
#define DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS 10
#define CAN_BITRATE 500UL * 1000UL
#define CAN_OSCILLATOR ACAN2517Settings::OSC_40MHz
#define SPI_CAN_CS 10
#define SPI_CAN_INT 3

static ACAN2517 acan = ACAN2517(SPI_CAN_CS, SPI, SPI_CAN_INT); // declared outside the class to be available in the acan.begin lambda, could this be avoided?

class Can {
  public :
    unsigned long aliveEmittingTimestamp;
    unsigned long digitalAndAnalogPinStatusesTimestamp;

    CANMessage receivedFrame;
    uint8_t aliveCounter;

    Can() {
      aliveCounter = 0;
    };

    void begin();
    void receive();
    void emit(CANMessage frame);
    void emitAlive(uint16_t aliveFrameId);
    bool* parseDigitalPinRequest();
    OtherPinDutyCycles parseOtherPinRequest();
    uint8_t extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight);
    void emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinsStatusFrameId, uint8_t digitalPinsStatus[21], uint16_t analogPinsStatus[3]);
};

#endif

