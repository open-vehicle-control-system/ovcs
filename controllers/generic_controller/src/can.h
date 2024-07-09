#ifndef CAN_H
#define CAN_H

#include <Arduino.h>
#include <ACAN2517.h>
#include <SPI.h>

#define ALIVE_FRAME_FREQUENCY_MS 100
#define DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS 10
#define CAN_BITRATE 500UL * 1000UL
#define CAN_OSCILLATOR ACAN2517Settings::OSC_40MHz

static const byte MCP2517_CS  = 10;
static const byte MCP2517_INT = 3;
static ACAN2517 acan          = ACAN2517(MCP2517_CS, SPI, MCP2517_INT);

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
    uint8_t extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight);
    void emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinsStatusFrameId, uint8_t digitalPinsStatus[21], uint16_t analogPinsStatus[3]);
};

#endif

