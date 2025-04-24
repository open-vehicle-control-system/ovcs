#ifndef CAN_H
#define CAN_H

#include <Arduino.h>
#include <Debug.h>
#include <ACAN2517.h>
#include <SPI.h>
#include <OtherPinDutyCycle.h>
#include <ExternalPwm.h>
#include <Vms.h>
#include <ControllerStatus.h>
#include <VmsCommand.h>

#define CAN_BITRATE 1000UL * 1000UL
#define CAN_OSCILLATOR ACAN2517Settings::OSC_40MHz
#define SPI_CAN_CS 10
#define SPI_CAN_INT 3

static ACAN2517 acan = ACAN2517(SPI_CAN_CS, SPI, SPI_CAN_INT); // declared outside the class to be available in the acan.begin lambda, could this be avoided?

class Can {
  public :
    CANMessage _receivedFrame;

    Can() {
      _aliveCounter = 0;
    };

    void begin();
    void receive();
    void emitAlive(uint16_t aliveFrameId, uint8_t expansionBoard1LastError, uint8_t expansionBoard2LastError, ControllerStatus status);
    PinStatus* parseDigitalPinRequest();
    OtherPinDutyCycles parseOtherPinRequest();
    ExternalPwm parseExternalPwmRequest();
    Vms parseVmsAliveFrame();
    VmsCommand parseVmsCommandFrame();
    void emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinsStatusFrameId, PinStatus digitalPinsStatus[19], uint16_t analogPinsStatus[3]);

  private:
    uint8_t _aliveCounter;
    void emit(CANMessage frame);
    uint8_t extractBits(uint16_t source, uint16_t mask, uint8_t shiftRight);
};

#endif
