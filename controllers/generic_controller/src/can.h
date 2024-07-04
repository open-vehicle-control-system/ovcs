#ifndef CAN_H
#define CAN_H

#include <Arduino.h>
#include <ACAN2517.h>
#include <SPI.h>

static const byte MCP2517_CS  = 10;
static const byte MCP2517_INT = 3;
static ACAN2517 acan          = ACAN2517(MCP2517_CS, SPI, MCP2517_INT);

class Can {
  public :
    CANMessage receivedFrame;

    Can() {};

    void begin();
    void receive();
    void emit(CANMessage frame);
};

#endif

