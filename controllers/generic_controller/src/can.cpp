#include <can.h>

void Can::begin() {
  SPI.begin ();
  ACAN2517Settings settings (ACAN2517Settings::OSC_40MHz, 500UL * 1000UL);
  settings.mDriverTransmitFIFOSize = 1;
  settings.mDriverReceiveFIFOSize  = 1;
  const uint32_t errorCode = acan.begin (settings, [] { acan.isr () ; });
  if (errorCode == 0) {
    Serial.println("> CAN Ready");
  } else {
    Serial.print ("> CAN Configuration error 0x");
    Serial.println (errorCode, HEX);
  }
};

void Can::receive() {
  if (acan.available()) {
    acan.receive(receivedFrame);
  } else {
    receivedFrame.id = 0;
  }
};

void Can::emit(CANMessage frame) {
  const bool ok = acan.tryToSend (frame) ;
  if (!ok) {
    Serial.println ("CAN emit failure") ;
  }
};

void Can::emitAlive(uint16_t aliveFrameId) {
  unsigned long now = millis();
  if(aliveEmittingTimestamp + ALIVE_FRAME_FREQUENCY_MS <= now){
    aliveEmittingTimestamp = now;
    CANMessage frame;
    frame.id      = aliveFrameId;
    frame.len     = 1;
    frame.data[0] = aliveCounter;
    aliveCounter  = (aliveCounter + 1) % 3;
    emit(frame);
  }
};

void Can::emitdigitalAndAnalogPinsStatus(uint16_t digitalAndAnalogPinStatusesFrameId, uint8_t digitalPinsStatus [21], uint16_t analogPinsStatus [3]) {
  unsigned long now = millis();
  if(digitalAndAnalogPinStatusesTimestamp + DIGITAL_AND_ANALOG_PINS_STATUS_FRAME_FREQUENCY_MS <= now){
    digitalAndAnalogPinStatusesTimestamp = now;
    CANMessage frame;
    frame.id  = digitalAndAnalogPinStatusesFrameId;
    frame.len = 8;
    for(uint8_t i=0; i < 21; i++) {
      uint8_t frameNumber = i / 8;
      uint8_t bitNumber   = 7 - (i % 8);
      bitWrite(frame.data[frameNumber], bitNumber, digitalPinsStatus[i]);
    }

    emit(frame);
  }
};